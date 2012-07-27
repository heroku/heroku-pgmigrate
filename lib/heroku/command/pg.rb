require "heroku/command/base"

module Heroku::Command
  class Pg < BaseWithApp

    # pg:migrate
    #
    # Migrate from legacy shared databases to Heroku Postgres Dev
    def migrate
      validate_arguments!

      todo = []
      undoing = []

      provision_dev = Heroku::PgMigrate::ProvisionDev.new
      maintainance = Heroku::PgMigrate::Maintenance.new
      scale_zero = Heroku::PgMigrate::ScaleZero.new

      # In reverse order of doing, since this is a stack of actions
      todo << scale_zero
      todo << maintenance
      todo << provision_dev

      # Always want to undo some actions.
      undoing << maintenance
      undoing << scale_zero

      begin
        loop do
          action = todo.pop()

          # Finished all actions without a problem
          break if action.nil?

          begin
            additional = action.perform!
          rescue Heroku::PgMigrate::NeedsUndoing => error
            undoing.push(action)
            raise
          end

          todo.concat(additional)
        end
      rescue
        # Regardless, rollbacks need a chance to execute
        process_undo(undoing)
        raise
      end
    end

    def self.process_undo(undoing)
      # Process rollbacks in 'undoing'
      #
      # Rollbacks are intended to be idempotent and we'd *really*
      # prefer them run until they are successful, no matter what.
      loop do
        action = undoing.pop()
        break if action.nil?
        begin
          action.rollback!
        rescue
          status($!.to_s)
          status("Rollback failed: retrying.")
        end
      end
    end

  end

  module Heroku::PgMigrate
    module NeedsUndoing
    end

    class Maintenance
      def perform!
        status("Entering maintenance mode on application #{app}.")

        begin
          api.post_app_maintenance(app, '1')
        rescue
          error.extend(NeedsUndoing)
          raise
        end

        return []
      end

      def rollback!
        status("Leaving maintenance mode on application #{app}.")
        api.post_app_maintenance(app, '0')
      end
    end

    class ScaleZero
      def perform!
        @old_counts = nil

        # Remember the previous scaling for rollback.  Can fail.
        @old_counts = process_count(api, app)

        begin
          # Perform the actual de-scaling
          self.scale_zero api, app, @old_counts.keys
        rescue StandardError => error
          # If something goes wrong, signal caller to try to rollback by
          # tagging the error -- it's presumed one or more processes
          # have been scaled to zero.
          error.extend(NeedsUndoing)
          raise
        end

        return []
      end

      def rollback!
        if @old_counts == nil
          error("Internal error: attempt to restore process scale when " +
            "process scale-down could not be performed successfully.")
        end

        @old_counts.each { |name, amount|
          status("Restoring process #{name} scale to #{amount}.")
          api.post_ps_scale(app, name, amount.to_s).body
        }
      end
    end

    #
    # Helper procedures
    #

    def self.process_count api, app
      # Read an app's process names and compute their quantity.

      processes = api.get_ps(app).body
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

        return old_counts
      end

      def self.scale_zero(api, app, names)
        # Scale every process contained in the sequence 'names' to zero.

        names.each { |name|
          status("Scaling process ${name} to 0.")
          api.post_ps_scale(app, name, '0')
        }

        nil
      end
    end

    class RebindConfig
      def initialize new
        @new = new
        @old = nil
        @rebinding = nil
      end

      def perform!
        # Save vars in case of rollback scenario.
        api.get_config_vars(app).body

        # Find and confirm the SHARED_DATABASE_URL's existence
        @old = vars['SHARED_DATABASE_URL']
        if @old == nil
          error("No SHARED_DATABASE_URL found: cannot migrate.")
        end

        # Compute all the configuration variables that need rebinding.
        rebinding = find_rebindings(vars, @old)

        # Indicate what is about to be done
        status("Binding new database configuration to: " +
          "#{humanize(rebinding)}.")

        # Set up state for rollback
        @rebinding = rebinding

        begin
          rebind(api, app, rebinding, @new)
        rescue StandardError => error
          # If this fails, rollback is necessary
          error.extend(NeedsUndoing)
          raise
        end

        return []
      end

      def rollback!
        if @rebinding.nil? || @old.nil?
          # Apparently, perform! never got far enough to bind enough
          # rollback state.
          error("Internal error: rollback performed even though " +
            "this action should not require undoing.")
        end

        status("Binding old database configuration to: " +
          "#{humanize(@rebinding)}")
        rebind(api, app, @rebinding, @old)
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

    class ProvisionDev
      def perform!
        dev_plan = nil
        configure_addon('Adding') do |addon, config|
          # What does this return? A successful addition should be
          # able to advertise its name.
          dev_plan = heroku.install_addon(app, 'heroku-postgresql:dev', config)
        end

        return [RebindConfig.new(new_dev_url)]
      end

      def rollback!
        # There are probably some situations where it is safe to
        # delete the addon to rollback, but instead it may be better
        # to just report the name of the extra addon left behind by an
        # incomplete migrate process.
      end
    end
  end
end
