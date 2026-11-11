# frozen_string_literal: true

require 'legion/logging/helper'

require 'sequel/extensions/migration'

module Legion
  module Data
    module Migration
      class << self
        include Legion::Logging::Helper

        def migrate(connection = Legion::Data.connection, path = "#{__dir__}/migrations", **)
          if defined?(Legion::Mode) && Legion::Mode.respond_to?(:current) && !Legion::Mode.infra?
            log.info "Legion::Data::Migration skipped (mode: #{Legion::Mode.current}, requires: infra)"
            return
          end

          if connection.database_type == :postgres
            role_state = connection.fetch(<<~SQL).first
              SELECT session_user,
                     current_user,
                     current_setting('role') AS active_role,
                     to_regrole('legionio_migrator')::text AS migrator_role,
                     CASE
                       WHEN to_regrole('legionio_migrator') IS NULL THEN NULL
                       ELSE pg_has_role(session_user, 'legionio_migrator', 'MEMBER')
                     END AS migrator_member,
                     CASE
                       WHEN to_regrole('legionio_migrator') IS NULL THEN NULL
                       ELSE pg_has_role(session_user, 'legionio_migrator', 'SET')
                     END AS migrator_set,
                     has_schema_privilege(session_user, 'public', 'CREATE') AS session_create,
                     has_schema_privilege(current_user, 'public', 'CREATE') AS current_create,
                     CASE
                       WHEN to_regrole('legionio_migrator') IS NULL THEN NULL
                       ELSE has_schema_privilege('legionio_migrator', 'public', 'CREATE')
                     END AS migrator_create
            SQL
            Legion::Logging.unknown "migration role state=#{role_state.inspect}"
          end

          Legion::Settings[:data][:migrations][:version] = Sequel::Migrator.run(connection, path, **)
          log.info("Legion::Data::Migration ran successfully to version #{Legion::Settings[:data][:migrations][:version]}")
          Legion::Settings[:data][:migrations][:ran] = true
        rescue Sequel::DatabaseError => e
          handle_exception(e, level: :error, handled: false, operation: :migrate, path: path)
          if e.message.include?('InsufficientPrivilege') || e.message.include?('permission denied')
            raise Sequel::DatabaseError,
                  "#{e.message}\n  Hint: the database user lacks CREATE on schema public " \
                  '(required for PG 15+). Grant via: GRANT CREATE ON SCHEMA public TO <user>;'
          end
          raise
        end
      end
    end
  end
end
