# frozen_string_literal: true

module Legion
  module Data
    module DatabaseLock
      def self.with_claim(database:, table:, key:)
        options = { savepoint: true }
        options[:mode] = :immediate if database.database_type == :sqlite
        database.transaction(**options) do
          claim = database[table].where(key)
          # InnoDB needs exclusive duplicate-key locks to avoid shared-lock upgrade deadlocks.
          claim = claim.on_duplicate_key_update(*key.keys) if database.database_type == :mysql
          claim.insert(key)
          result = yield
          # The unique-key lock lasts until commit; historical keys need no retained rows.
          claim.delete
          result
        end
      end
    end
  end
end
