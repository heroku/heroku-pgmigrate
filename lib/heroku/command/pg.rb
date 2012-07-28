require "heroku/command/base"

class Heroku::Command::Pg < Heroku::Command::Base

  include Heroku::Helpers

  # pg:migrate
  #
  # Migrate from legacy shared databases to Heroku Postgres Dev
  def migrate
    to_perform = []
    rollbacks = []

    maintenance = Heroku::PgMigrate::Maintenance.new(api, app)
    scale_zero! = Heroku::PgMigrate::ScaleZero.new(api, app)

    # In reverse order of performance, as to_perform is a stack.
    to_perform << scale_zero!
    to_perform << maintenance

    # Always want to rollback some xacts.
    rollbacks << maintenance
    rollbacks << scale_zero!

    begin
      loop do
        xact = to_perform.pop()

        # Finished all xacts without a problem
        break if xact.nil?

        begin
          additional = xact.perform!
        rescue Heroku::PgMigrate::NeedRollback => error
          rollbacks.push(xact)
          raise
        end

        to_perform.concat(additional)
      end
    ensure
      # Regardless, rollbacks need a chance to execute
      process_rollbacks(rollbacks)
    end
  end

  def process_rollbacks(rollbacks)
    # Rollbacks are intended to be idempotent (as they may get run
    # one or more times unless someone completely kills the program)
    # and we'd *really* prefer them run until they are successful,
    # no matter what.
    loop do
      xact = rollbacks.pop()
      break if xact.nil?

      begin
        xact.rollback!
      rescue
        puts $!.to_s
      end
    end
  end

end

module Heroku::PgMigrate
end

module Heroku::PgMigrate::NeedRollback
end

class Heroku::PgMigrate::Maintenance
  include Heroku::Helpers

  def initialize api, app
    @api = api
    @app = app
  end

  def perform!
    action("Entering maintenance mode on application #{@app}") {

      begin
        @api.post_app_maintenance(@app, '1')
      rescue
        error.extend(NeedRollback)
        raise
      end

      status("success")
    }

    return []
  end

  def rollback!
    action("Leaving maintenance mode on application #{@app}") {
      @api.post_app_maintenance(@app, '0')
      status("success")
    }
  end
end

class Heroku::PgMigrate::ScaleZero
  include Heroku::Helpers

  def initialize api, app
    @api = api
    @app = app
  end

  def perform!
    @old_counts = nil

    # Remember the previous scaling for rollback.  Can fail.
    @old_counts = self.class.process_count(@api, @app)

    begin
      # Perform the actual de-scaling
      #
      # TODO: special case handling of "run" type processes
      scale_zero!(@old_counts.keys)
    rescue StandardError => error
      # If something goes wrong, signal caller to try to rollback by
      # tagging the error -- it's presumed one or more processes
      # have been scaled to zero.
      error.extend(NeedRollback)
      raise
    end

    return []
  end

  def rollback!
    if @old_counts == nil
      raise "Internal error: attempt to restore process scale when " +
        "process scale-down could not be performed successfully."
    end

    @old_counts.each { |name, amount|
      action("Restoring process #{name} scale to #{amount}") {
        @api.post_ps_scale(app, name, amount.to_s).body
        status('success')
      }
    }
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
    names.each { |name|
      action("Scaling process ${name} to 0") {
        @api.post_ps_scale(@app, name, '0')
        status('success')
      }
    }

    nil
  end
end

class Heroku::PgMigrate::RebindConfig
  include Heroku::Helpers

  def initialize api, new
    @api = api
    @new = new
    @old = nil
    @rebinding = nil
  end

  def perform!
    # Save vars in case of rollback scenario.
    @api.get_config_vars(app).body

    # Find and confirm the SHARED_DATABASE_URL's existence
    @old = vars['SHARED_DATABASE_URL']
    if @old == nil
      raise "No SHARED_DATABASE_URL found: cannot migrate."
    end

    # Compute all the configuration variables that need rebinding.
    rebinding = self.class.find_rebindings(vars, @old)

    # Indicate what is about to be done
    action("Binding new database configuration to: " +
      "#{self.class.humanize(rebinding)}") {

      # Set up state for rollback
      @rebinding = rebinding

      begin
        self.class.rebind(@api, app, rebinding, @new)
      rescue StandardError => error
        # If this fails, rollback is necessary
        error.extend(NeedRollback)
        raise
      end

      status('success')
    }

    return []
  end

  def rollback!
    if @rebinding.nil? || @old.nil?
      # Apparently, perform! never got far enough to bind enough
      # rollback state.
      raise "Internal error: rollback performed even though " +
        "this action should not require undoing."

      action("Binding old database configuration to: " +
        "#{self.class.humanize(@rebinding)}") {
        rebind(@api, app, @rebinding, @old)
        status('success')
      }
    end


    #
    # Helper procedures
    #

    def self.find_rebindings(vars, val)
      # Yield each configuration variable with a given value.
      rebinding = []
      vars.each { |name, val|
        if val == @old
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
end
