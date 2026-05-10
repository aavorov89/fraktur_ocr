# River migration DDL embedded inline so `bin/rails db:migrate` provisions
# the queue tables that services/render (Go) consumes.
#
# Source: github.com/riverqueue/river/riverdriver/riverpgxv5 v0.36.0,
# files migration/main/001..006.{up,down}.sql. Keep this version in sync
# with services/render/go.mod when bumping river.
class InstallRiver < ActiveRecord::Migration[8.1]
  RIVER_VERSION = 6 # last river migration version applied below

  def up
    return skip_non_pg unless postgres?

    execute <<~SQL
      CREATE TABLE river_migration(
        line TEXT NOT NULL,
        version bigint NOT NULL,
        created_at timestamptz NOT NULL DEFAULT NOW(),
        CONSTRAINT line_length CHECK (char_length(line) > 0 AND char_length(line) < 128),
        CONSTRAINT version_gte_1 CHECK (version >= 1),
        PRIMARY KEY (line, version)
      );
    SQL

    execute <<~SQL
      CREATE TYPE river_job_state AS ENUM(
        'available',
        'cancelled',
        'completed',
        'discarded',
        'pending',
        'retryable',
        'running',
        'scheduled'
      );

      CREATE TABLE river_job(
        id bigserial PRIMARY KEY,
        state river_job_state NOT NULL DEFAULT 'available',
        attempt smallint NOT NULL DEFAULT 0,
        max_attempts smallint NOT NULL,
        attempted_at timestamptz,
        created_at timestamptz NOT NULL DEFAULT NOW(),
        finalized_at timestamptz,
        scheduled_at timestamptz NOT NULL DEFAULT NOW(),
        priority smallint NOT NULL DEFAULT 1,
        args jsonb NOT NULL,
        attempted_by text[],
        errors jsonb[],
        kind text NOT NULL,
        metadata jsonb NOT NULL DEFAULT '{}',
        queue text NOT NULL DEFAULT 'default',
        tags varchar(255)[] NOT NULL DEFAULT '{}',
        unique_key bytea,
        unique_states BIT(8),
        CONSTRAINT finalized_or_finalized_at_null CHECK (
            (finalized_at IS NULL AND state NOT IN ('cancelled', 'completed', 'discarded')) OR
            (finalized_at IS NOT NULL AND state IN ('cancelled', 'completed', 'discarded'))
        ),
        CONSTRAINT max_attempts_is_positive CHECK (max_attempts > 0),
        CONSTRAINT priority_in_range CHECK (priority >= 1 AND priority <= 4),
        CONSTRAINT queue_length CHECK (char_length(queue) > 0 AND char_length(queue) < 128),
        CONSTRAINT kind_length CHECK (char_length(kind) > 0 AND char_length(kind) < 128)
      );

      CREATE INDEX river_job_kind ON river_job USING btree(kind);
      CREATE INDEX river_job_state_and_finalized_at_index ON river_job USING btree(state, finalized_at) WHERE finalized_at IS NOT NULL;
      CREATE INDEX river_job_prioritized_fetching_index ON river_job USING btree(state, queue, priority, scheduled_at, id);
      CREATE INDEX river_job_args_index ON river_job USING GIN(args);
      CREATE INDEX river_job_metadata_index ON river_job USING GIN(metadata);

      CREATE UNLOGGED TABLE river_leader(
        elected_at timestamptz NOT NULL,
        expires_at timestamptz NOT NULL,
        leader_id text NOT NULL,
        name text PRIMARY KEY DEFAULT 'default',
        CONSTRAINT name_length CHECK (name = 'default'),
        CONSTRAINT leader_id_length CHECK (char_length(leader_id) > 0 AND char_length(leader_id) < 128)
      );

      CREATE TABLE river_queue (
        name text PRIMARY KEY NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
        paused_at timestamptz,
        updated_at timestamptz NOT NULL
      );

      CREATE UNLOGGED TABLE river_client (
        id text PRIMARY KEY NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        metadata jsonb NOT NULL DEFAULT '{}',
        paused_at timestamptz,
        updated_at timestamptz NOT NULL,
        CONSTRAINT name_length CHECK (char_length(id) > 0 AND char_length(id) < 128)
      );

      CREATE UNLOGGED TABLE river_client_queue (
        river_client_id text NOT NULL REFERENCES river_client (id) ON DELETE CASCADE,
        name text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        max_workers bigint NOT NULL DEFAULT 0,
        metadata jsonb NOT NULL DEFAULT '{}',
        num_jobs_completed bigint NOT NULL DEFAULT 0,
        num_jobs_running bigint NOT NULL DEFAULT 0,
        updated_at timestamptz NOT NULL,
        PRIMARY KEY (river_client_id, name),
        CONSTRAINT name_length CHECK (char_length(name) > 0 AND char_length(name) < 128),
        CONSTRAINT num_jobs_completed_zero_or_positive CHECK (num_jobs_completed >= 0),
        CONSTRAINT num_jobs_running_zero_or_positive CHECK (num_jobs_running >= 0)
      );
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION river_job_state_in_bitmask(bitmask BIT(8), state river_job_state)
      RETURNS boolean
      LANGUAGE SQL
      IMMUTABLE
      AS $fn$
        SELECT CASE state
          WHEN 'available' THEN get_bit(bitmask, 7)
          WHEN 'cancelled' THEN get_bit(bitmask, 6)
          WHEN 'completed' THEN get_bit(bitmask, 5)
          WHEN 'discarded' THEN get_bit(bitmask, 4)
          WHEN 'pending'   THEN get_bit(bitmask, 3)
          WHEN 'retryable' THEN get_bit(bitmask, 2)
          WHEN 'running'   THEN get_bit(bitmask, 1)
          WHEN 'scheduled' THEN get_bit(bitmask, 0)
          ELSE 0
        END = 1;
      $fn$;

      CREATE UNIQUE INDEX river_job_unique_idx ON river_job (unique_key)
        WHERE unique_key IS NOT NULL
          AND unique_states IS NOT NULL
          AND river_job_state_in_bitmask(unique_states, state);
    SQL

    (1..RIVER_VERSION).each do |version|
      execute "INSERT INTO river_migration (line, version) VALUES ('main', #{version})"
    end
  end

  def down
    return skip_non_pg unless postgres?

    execute <<~SQL
      DROP INDEX IF EXISTS river_job_unique_idx;
      DROP FUNCTION IF EXISTS river_job_state_in_bitmask(bitmask BIT(8), state river_job_state);
      DROP TABLE IF EXISTS river_client_queue;
      DROP TABLE IF EXISTS river_client;
      DROP TABLE IF EXISTS river_queue;
      DROP TABLE IF EXISTS river_leader;
      DROP TABLE IF EXISTS river_job;
      DROP TYPE IF EXISTS river_job_state;
      DROP TABLE IF EXISTS river_migration;
    SQL
  end

  private

  def postgres?
    ActiveRecord::Base.connection.adapter_name =~ /postg/i
  end

  def skip_non_pg
    say "Skipping river DDL — adapter is #{ActiveRecord::Base.connection.adapter_name}, not PostgreSQL.", true
  end
end
