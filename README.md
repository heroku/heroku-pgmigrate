# heroku pg:migrate

## Installation

    # upgrade to the latest heroku gem
    gem update heroku
    # install this plugin
    heroku plugins:install git://github.com/heroku/heroku-pgmigrate

## Usage

In short: `heroku pg:migrate --app your_app`

This command will move from the legacy Shared Database plans to the
newer Heroku Postgres Dev plans.  This is done using a series of API
calls that have been available for some time, and a few new ones made
to this purpose.

The general process used internally by the software is as follows:

    # Add a pgbackups:plus plan, if no pgbackups plan is found at all
    heroku addons:add pgbackups:plus -a <appname>

    # Create a Dev plan as a target to do a pgbackups restore into
    heroku addons:add heroku-postgresql:dev -a <appname>

    # Set maintenance mode
    heroku maintenance:on -a <appname>

    # Scale all processes to zero
    heroku scale <all-process-types>=0 -a <appname>

    # Copy the database (this API is not currently exposed via command
    # line)
    heroku pgbackups:transfer <SHARED_DATABASE_URL> <DEV_PLAN_URL> -a <appname>

    # Having confirmed that it succeeds...
    #
    # Rebind all config variables that had the SHARED_DATABASE_URL to
    # the new DEV_PLAN_URL.  SHARED_DATABASE_URL will also be rebound
    # to the dev addon.
    heroku config:add <...> -a <appname>

    # Now that everything is reconfigured, bring the app back up
    heroku scale <all-process-types>=<original-value> -a <appname>
    heroku maintenance:off -a <appname>

## Bugs

`pg:migrate` can be dangerous if one has moved, duplicated, or
overwritten their SHARED_DATABASE_URL configuration, including both
within one application and between multiple applications.

`pg:migrate` is not safe to use under concurrent access (multiple
users at the same time).  In event of an abort, it may be necessary to
determine:

  * If one wishes to roll back the attempt to migrate and try again,
    whether one should delete the target dev-plan database, as
    migrations are safest to completely empty database.

  * If the database was properly restored into its destination

  * If one wishes to use the new database or old database URL

  * If one needs to rebind any config variables, should config var
    rewriting have only half-completed.

  * If one wishes to turn off maintenance mode and scale processes
    back to their original level, after assessing that all config vars
    are in the correct state.


## THIS IS BETA SOFTWARE

Thanks for trying it out. If you find any issues, please notify us at
support@heroku.com
