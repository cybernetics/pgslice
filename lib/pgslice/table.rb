module PgSlice
  class Table
    attr_reader :table

    def initialize(table)
      @table = table.to_s
    end

    def to_s
      table
    end

    def intermediate_table
      self.class.new("#{table}_intermediate")
    end

    def retired_table
      self.class.new("#{table}_retired")
    end

    def exists?
      existing_tables(like: table).any?
    end

    def trigger_name
      "#{table.split(".")[-1]}_insert_trigger"
    end

    def column_cast(column)
      data_type = execute("SELECT data_type FROM information_schema.columns WHERE table_schema || '.' || table_name = $1 AND column_name = $2", [table, column])[0]["data_type"]
      data_type == "timestamp with time zone" ? "timestamptz" : "date"
    end

    def columns
      execute("SELECT column_name FROM information_schema.columns WHERE table_schema || '.' || table_name = $1", [table]).map{ |r| r["column_name"] }
    end

    # http://www.dbforums.com/showthread.php?1667561-How-to-list-sequences-and-the-columns-by-SQL
    def sequences
      query = <<-SQL
        SELECT
          a.attname as related_column,
          s.relname as sequence_name
        FROM pg_class s
          JOIN pg_depend d ON d.objid = s.oid
          JOIN pg_class t ON d.objid = s.oid AND d.refobjid = t.oid
          JOIN pg_attribute a ON (d.refobjid, d.refobjsubid) = (a.attrelid, a.attnum)
          JOIN pg_namespace n ON n.oid = s.relnamespace
        WHERE s.relkind = 'S'
          AND n.nspname = $1
          AND t.relname = $2
      SQL
      execute(query, table.split(".", 2))
    end

    def foreign_keys
      execute("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = #{regclass(table)} AND contype ='f'").map { |r| r["pg_get_constraintdef"] }
    end

    # http://stackoverflow.com/a/20537829
    def primary_key
      query = <<-SQL
        SELECT
          pg_attribute.attname,
          format_type(pg_attribute.atttypid, pg_attribute.atttypmod)
        FROM
          pg_index, pg_class, pg_attribute, pg_namespace
        WHERE
          nspname || '.' || relname = $1 AND
          indrelid = pg_class.oid AND
          pg_class.relnamespace = pg_namespace.oid AND
          pg_attribute.attrelid = pg_class.oid AND
          pg_attribute.attnum = any(pg_index.indkey) AND
          indisprimary
      SQL
      execute(query, [table]).map { |r| r["attname"] }
    end

    def max_id(primary_key, below: nil, where: nil)
      query = "SELECT MAX(#{quote_ident(primary_key)}) FROM #{quote_table(table)}"
      conditions = []
      conditions << "#{quote_ident(primary_key)} <= #{below}" if below
      conditions << where if where
      query << " WHERE #{conditions.join(" AND ")}" if conditions.any?
      execute(query)[0]["max"].to_i
    end

    def min_id(primary_key, column, cast, starting_time, where)
      query = "SELECT MIN(#{quote_ident(primary_key)}) FROM #{quote_table(table)}"
      conditions = []
      conditions << "#{quote_ident(column)} >= #{sql_date(starting_time, cast)}" if starting_time
      conditions << where if where
      query << " WHERE #{conditions.join(" AND ")}" if conditions.any?
      (execute(query)[0]["min"] || 1).to_i
    end

    def existing_partitions(period = nil)
      count =
        case period
        when "day"
          8
        when "month"
          6
        else
          "6,8"
        end

      existing_tables(like: "#{table}_%").select { |t| /\A#{Regexp.escape("#{table}_")}\d{#{count}}\z/.match(t) }
    end

    def fetch_comment
      execute("SELECT obj_description(#{regclass(table)}) AS comment")[0]
    end

    def fetch_trigger(trigger_name)
      execute("SELECT obj_description(oid, 'pg_trigger') AS comment FROM pg_trigger WHERE tgname = $1 AND tgrelid = #{regclass(table)}", [trigger_name])[0]
    end

    def index_defs
      execute("SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indrelid = #{regclass(table)} AND indisprimary = 'f'").map { |r| r["pg_get_indexdef"] }
    end

    private

    def existing_tables(like:)
      query = "SELECT schemaname, tablename FROM pg_catalog.pg_tables WHERE schemaname = $1 AND tablename LIKE $2"
      execute(query, like.split(".", 2)).map { |r| "#{r["schemaname"]}.#{r["tablename"]}" }.sort
    end

    def execute(*args)
      $client.send(:execute, *args)
    end

    def quote_ident(value)
      PG::Connection.quote_ident(value)
    end

    def quote_table(table)
      table.to_s.split(".", 2).map { |v| quote_ident(v) }.join(".")
    end

    def quote_no_schema(table)
      quote_ident(table.to_s.split(".", 2)[-1])
    end

    def regclass(table)
      "'#{quote_table(table)}'::regclass"
    end

    def sql_date(time, cast, add_cast = true)
      if cast == "timestamptz"
        fmt = "%Y-%m-%d %H:%M:%S UTC"
      else
        fmt = "%Y-%m-%d"
      end
      str = "'#{time.strftime(fmt)}'"
      add_cast ? "#{str}::#{cast}" : str
    end
  end
end
