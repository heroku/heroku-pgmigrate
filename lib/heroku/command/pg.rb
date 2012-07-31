require 'thread'

require "heroku/command/base"

class Heroku::Command::Pg < Heroku::Command::Base

  include Heroku::Helpers

  # pg:migrate
  #
  # Migrate from legacy shared databases to Heroku Postgres Dev
  def migrate
    maintenance = Heroku::PgMigrate::Maintenance.new(api, app)
    scale_zero = Heroku::PgMigrate::ScaleZero.new(api, app)
    rebind = Heroku::PgMigrate::RebindConfig.new(api, app)
    provision = Heroku::PgMigrate::Provision.new(api, app)

    mp = Heroku::PgMigrate::MultiPhase.new()
    mp.enqueue(provision)
    mp.enqueue(maintenance)
    mp.enqueue(scale_zero)
    mp.enqueue(rebind)
    mp.engage()
  end
end

module Heroku::PgMigrate
end

module Heroku::PgMigrate::NeedRollback
end

module Heroku::PgMigrate
  XactEmit = Struct.new(:more_actions, :more_rollbacks, :feed_forward)
end

class Heroku::PgMigrate::CannotMigrate < RuntimeError
end

class Heroku::PgMigrate::MultiPhase
  def initialize()
    @to_perform = Queue.new
    @rollbacks = []
  end

  def enqueue(xact)
    @to_perform.enq(xact)
  end

  def engage
    begin
      feed_forward = {}
      loop do
        xact = @to_perform.deq()

        # Finished all xacts without a problem
        break if xact.nil?

        emit = nil

        begin
          emit = xact.perform!(feed_forward)
        rescue Heroku::PgMigrate::NeedRollback => error
          @rollbacks.push(xact)
          raise
        end

        emit.more_actions.each { |nx|
          @to_perform.enq(nx)
        }

        @rollbacks.concat(emit.more_rollbacks)
        if emit.feed_forward != nil
          # Use the class value as a way to coordinate between
          # different steps.
          #
          # In principle, though, the class is not required per se,
          # one only neesd a value that multiple passes can know about
          # before beginning execution yet is known to be unique among
          # all actions in execution.
          feed_forward[xact.class] = emit.feed_forward
        end
      end
    ensure
      # Regardless, rollbacks need a chance to execute
      self.class.process_rollbacks(@rollbacks)
    end
  end

  def self.process_rollbacks(rollbacks)
    # Rollbacks are intended to be idempotent (as they may get run
    # one or more times unless someone completely kills the program)
    # and we'd *really* prefer them run until they are successful,
    # no matter what.
    loop do
      xact = rollbacks.pop()
      break if xact.nil?

      begin
        # Some actions have no sensible rollback, but this conditional
        # allows them to avoid writing noop rollback! methods all the
        # time.
        if xact.respond_to?(:rollback!)
          xact.rollback!
        end
      rescue
        puts $!.to_s
      end
    end
  end
end

class Heroku::PgMigrate::Maintenance
  include Heroku::Helpers

  def initialize(api, app)
    @api = api
    @app = app
  end

  def perform!(ff)
    action("Entering maintenance mode on application #{@app}") {
      @api.post_app_maintenance(@app, '1')
    }

    # Always want to rollback, regardless of exceptions or their
    # absence.  However, exceptions must be propagated as to
    # interrupt continued execution.
    return Heroku::PgMigrate::XactEmit.new([], [self], nil)
  rescue StandardException => error
    error.extend(Heroku::PgMigrate::NeedRollback)
    raise
  end

  def rollback!
    action("Leaving maintenance mode on application #{@app}") {
      @api.post_app_maintenance(@app, '0')
    }
  end
end

class Heroku::PgMigrate::ScaleZero
  include Heroku::Helpers

  def initialize api, app
    @api = api
    @app = app
  end

  def perform!(ff)
    @old_counts = nil

    # Remember the previous scaling for rollback.  Can fail.
    @old_counts = self.class.process_count(@api, @app)

    # Perform the actual de-scaling
    #
    # TODO: special case handling of "run" type processes
    scale_zero!(@old_counts.keys)

    # Just to not forget to handle this case later.
    hputs("WARNING: heroku run processes are not cancelled at this time")

    # Always want to rollback, regardless of exceptions or their
    # absence.  However, exceptions must be propagated as to
    # interrupt continued execution.
    return Heroku::PgMigrate::XactEmit.new([], [self], nil)
  rescue StandardException => error
    error.extend(Heroku::PgMigrate::NeedRollback)
    raise
  end

  def rollback!
    if @old_counts == nil
      # Must be true iff processes were never scaled down.
    else
      @old_counts.each { |name, amount|
        action("Restoring process #{name} scale to #{amount}") {
          @api.post_ps_scale(@app, name, amount.to_s).body
        }
      }
    end
  end

  #
  # Helper procedures
  #

  def self.process_count(api, app)
    # Read an app's process names and compute their quantity.

    processes = api.get_ps(app).body

    old_counts = {}
    processes.each do |process|
      name = process["process"].split(".").first

      # Is there a better way to ask the API for how many of each
      # process type is the target to be run?  Right now, compute it
      # by parsing the textual lines.
      if old_counts[name] == nil
        old_counts[name] = 1
      else
        old_counts[name] += 1
      end
    end

    return old_counts
  end

  def scale_zero! names
    # Scale every process contained in the sequence 'names' to zero.
    if names.empty?
      hputs("No active processes to scale down, skipping")
    else
      names.each { |name|
        action("Scaling process #{name} to 0") {
          @api.post_ps_scale(@app, name, '0')
        }
      }
    end

    return nil
  end
end

class Heroku::PgMigrate::RebindConfig
  include Heroku::Helpers

  def initialize(api, app)
    @api = api
    @app = app
    @old = nil
    @rebinding = nil
  end

  def perform!(ff)
    # Unpack information from provisioning step
    rebind_target = ff.fetch(Heroku::PgMigrate::Provision)
    env_var_value = rebind_target.fetch(:env_var_value)

    # Save vars in case of rollback scenario.
    vars = @api.get_config_vars(@app).body

    # Find and confirm the SHARED_DATABASE_URL's existence
    @old = vars['SHARED_DATABASE_URL']
    if @old == nil
      raise Heroku::PgMigrate::CannotMigrate.new(
        "No SHARED_DATABASE_URL found: cannot migrate.")
    end

    # Compute all the configuration variables that need rebinding.
    rebinding = self.class.find_rebindings(vars, @old)

    # Indicate what is about to be done
    action("Binding new database configuration to: " +
      "#{self.class.humanize(rebinding)}") {

      # Set up state for rollback
      @rebinding = rebinding

      begin
        self.class.rebind(@api, @app, rebinding, env_var_value)
      rescue StandardError => error
        # If this fails, rollback is necessary
        error.extend(Heroku::PgMigrate::NeedRollback)
        raise
      end
    }

    return Heroku::PgMigrate::XactEmit.new([], [], nil)
  end

  def rollback!
    if @rebinding.nil? || @old.nil?
      # Apparently, perform! never got far enough to bind enough
      # rollback state.
      raise "Internal error: rollback performed even though " +
        "this action should not require undoing."
    end

      action("Binding old database configuration to: " +
        "#{self.class.humanize(@rebinding)}") {
        rebind(@api, app, @rebinding, @old)
      }
  end


  #
  # Helper procedures
  #

  def self.find_rebindings(vars, old)
    # Yield each configuration variable with a given value.
    rebinding = []
    vars.each { |name, val|
      if val == old
        rebinding << name
      end
    }

    return rebinding
  end

  def self.rebind(api, app, names, val)
    # Rebind every configuration in 'names' to 'val'
    exploded_bindings = {}
    names.each { |name|
      exploded_bindings[name] = val
    }

    api.put_config_vars(app, exploded_bindings)
  end

  def self.humanize(names)
    # How a list of rebound configuration names are to be rendered
    names.join(', ')
  end
end

class Heroku::PgMigrate::Provision
  include Heroku::Helpers

  def initialize(api, app)
    @api = api
    @app = app
  end

  def perform!(ff)
    new_datval = nil
    config_var_name = nil

    action("Installing heroku-postgresql:dev") {
      addon = @api.post_addon(@app, 'heroku-postgresql:dev')

      # Parse out the bound variable name
      add_msg = addon.body["message"]
      add_msg =~ /^Attached as (HEROKU_POSTGRESQL_[A-Z]+)$/
      config_var_name = $1
      status("attached as #{config_var_name}")
      new_datval = @api.get_config_vars(@app).body[config_var_name]
    }

    forward = {
      :env_var_name => config_var_name,
      :env_var_value => new_datval
    }

    return Heroku::PgMigrate::XactEmit.new([], [], forward)
  end
end
