require "heroku/client/pgbackups"
require "heroku/helpers/heroku_postgresql"

class Heroku::Command::Pgbackups

  include Heroku::Helpers::HerokuPostgresql

  # pgbackups:transfer [DATABASE_FROM] DATABASE_TO
  #
  # capture a backup from a database id
  #
  # if no DATABASE_FROM is specified, defaults to DATABASE_URL
  # the database backup is transferred directly to DATABASE_TO without an intermediate s3 dump
  #
  def transfer
    db1 = shift_argument
    db2 = shift_argument

    if db2.nil?
      db2 = db1
      db1 = "DATABASE_URL"
    end

    from_name, from_url = hpg_resolve(db1)
    to_name, to_url = hpg_resolve(db2)
    validate_arguments!

    opts      = {}

    backup = transfer!(from_url, from_name, to_url, to_name, opts)
    backup = poll_transfer!(backup)

    if backup["error_at"]
      message  =   "An error occurred and your backup did not finish."
      message += "\nThe database is not yet online. Please try again." if backup['log'] =~ /Name or service not known/
      message += "\nThe database credentials are incorrect."           if backup['log'] =~ /psql: FATAL:/
      error(message)
    end
  end

end
