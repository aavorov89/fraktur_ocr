# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_11_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "river_job_state", ["available", "cancelled", "completed", "discarded", "pending", "retryable", "running", "scheduled"]

  # River's bulk-unique partial index references this stored function. Rails'
  # schema dumper cannot represent functions, so we re-create it here so
  # `db:schema:load` can install the index that depends on it.
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
  SQL

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "documents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "pdf_stored_at"
    t.datetime "updated_at", null: false
  end

  create_table "ocr_requests", force: :cascade do |t|
    t.text "corrected_text"
    t.text "correction_error"
    t.datetime "created_at", null: false
    t.text "crop_data"
    t.integer "document_id", null: false
    t.text "error_message"
    t.jsonb "metrics", default: {}, null: false
    t.integer "page_number", null: false
    t.text "recognized_text"
    t.decimal "rect_h", precision: 10, scale: 4
    t.decimal "rect_w", precision: 10, scale: 4
    t.decimal "rect_x", precision: 10, scale: 4
    t.decimal "rect_y", precision: 10, scale: 4
    t.integer "status", default: 0, null: false
    t.string "target_language", default: "RU"
    t.text "translated_text"
    t.text "translation_error"
    t.datetime "updated_at", null: false
    t.index ["document_id", "created_at"], name: "index_ocr_requests_on_document_id_and_created_at"
    t.index ["document_id"], name: "index_ocr_requests_on_document_id"
  end

  create_table "river_client", id: :text, force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.jsonb "metadata", default: {}, null: false
    t.timestamptz "paused_at"
    t.timestamptz "updated_at", null: false
    t.check_constraint "char_length(id) > 0 AND char_length(id) < 128", name: "name_length"
  end

  create_table "river_client_queue", primary_key: ["river_client_id", "name"], force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.bigint "max_workers", default: 0, null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "name", null: false
    t.bigint "num_jobs_completed", default: 0, null: false
    t.bigint "num_jobs_running", default: 0, null: false
    t.text "river_client_id", null: false
    t.timestamptz "updated_at", null: false
    t.check_constraint "char_length(name) > 0 AND char_length(name) < 128", name: "name_length"
    t.check_constraint "num_jobs_completed >= 0", name: "num_jobs_completed_zero_or_positive"
    t.check_constraint "num_jobs_running >= 0", name: "num_jobs_running_zero_or_positive"
  end

  create_table "river_job", force: :cascade do |t|
    t.jsonb "args", null: false
    t.integer "attempt", limit: 2, default: 0, null: false
    t.timestamptz "attempted_at"
    t.text "attempted_by", array: true
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.jsonb "errors", array: true
    t.timestamptz "finalized_at"
    t.text "kind", null: false
    t.integer "max_attempts", limit: 2, null: false
    t.jsonb "metadata", default: {}, null: false
    t.integer "priority", limit: 2, default: 1, null: false
    t.text "queue", default: "default", null: false
    t.timestamptz "scheduled_at", default: -> { "now()" }, null: false
    t.enum "state", default: "available", null: false, enum_type: "river_job_state"
    t.string "tags", limit: 255, default: [], null: false, array: true
    t.binary "unique_key"
    t.bit "unique_states", limit: 8
    t.index ["args"], name: "river_job_args_index", using: :gin
    t.index ["kind"], name: "river_job_kind"
    t.index ["metadata"], name: "river_job_metadata_index", using: :gin
    t.index ["state", "finalized_at"], name: "river_job_state_and_finalized_at_index", where: "(finalized_at IS NOT NULL)"
    t.index ["state", "queue", "priority", "scheduled_at", "id"], name: "river_job_prioritized_fetching_index"
    t.index ["unique_key"], name: "river_job_unique_idx", unique: true, where: "((unique_key IS NOT NULL) AND (unique_states IS NOT NULL) AND river_job_state_in_bitmask(unique_states, state))"
    t.check_constraint "char_length(kind) > 0 AND char_length(kind) < 128", name: "kind_length"
    t.check_constraint "char_length(queue) > 0 AND char_length(queue) < 128", name: "queue_length"
    t.check_constraint "finalized_at IS NULL AND (state <> ALL (ARRAY['cancelled'::river_job_state, 'completed'::river_job_state, 'discarded'::river_job_state])) OR finalized_at IS NOT NULL AND (state = ANY (ARRAY['cancelled'::river_job_state, 'completed'::river_job_state, 'discarded'::river_job_state]))", name: "finalized_or_finalized_at_null"
    t.check_constraint "max_attempts > 0", name: "max_attempts_is_positive"
    t.check_constraint "priority >= 1 AND priority <= 4", name: "priority_in_range"
  end

  create_table "river_leader", primary_key: "name", id: :text, default: "default", force: :cascade do |t|
    t.timestamptz "elected_at", null: false
    t.timestamptz "expires_at", null: false
    t.text "leader_id", null: false
    t.check_constraint "char_length(leader_id) > 0 AND char_length(leader_id) < 128", name: "leader_id_length"
    t.check_constraint "name = 'default'::text", name: "name_length"
  end

  create_table "river_migration", primary_key: ["line", "version"], force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "line", null: false
    t.bigint "version", null: false
    t.check_constraint "char_length(line) > 0 AND char_length(line) < 128", name: "line_length"
    t.check_constraint "version >= 1", name: "version_gte_1"
  end

  create_table "river_queue", primary_key: "name", id: :text, force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.jsonb "metadata", default: {}, null: false
    t.timestamptz "paused_at"
    t.timestamptz "updated_at", null: false
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "access_key"
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["access_key"], name: "index_users_on_access_key", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ocr_requests", "documents"
  add_foreign_key "river_client_queue", "river_client", name: "river_client_queue_river_client_id_fkey", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
end
