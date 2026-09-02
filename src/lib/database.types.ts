// Typisierung des Supabase-Schemas (Schema 1.0.0). Manuell gepflegt und mit
// den Migrationen in supabase/migrations abgeglichen. Kann später durch
// `supabase gen types typescript` ersetzt werden.

export type Department = 'sales' | 'training_admin' | 'ato'
export type UserRole = 'superadmin' | 'admin' | 'teamleader' | 'staff'
export type UiLanguage = 'de' | 'en'
export type CaseStatus = 'enquiry' | 'booked' | 'released' | 'in_progress' | 'completed' | 'discarded'
export type CheckpointState = 'open' | 'completed' | 'verified'
export type GateState = 'open' | 'in_progress' | 'released'
export type ExceptionState = 'requested' | 'approved' | 'rejected'
export type MessageScope = 'case' | 'trainee' | 'company'
export type NotificationType =
  | 'reminder' | 'escalation' | 'escalation_level2' | 'pool_stale' | 'mention'
  | 'gate_released' | 'exception_requested' | 'exception_decided' | 'assignment'
export type EmailState = 'pending' | 'sent' | 'failed' | 'skipped'
/** Einheitliches Statusmodell der Oberfläche (Spec 13). */
export type DisplayState = 'open' | 'in_progress' | 'done' | 'overdue' | 'discarded'

type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

type Table<Row, Insert = Partial<Row>, Update = Partial<Row>> = {
  Row: Row
  Insert: Insert
  Update: Update
  Relationships: []
}
type View<Row> = { Row: Row; Relationships: [] }

export type User = {
  id: string; name: string; email: string; department: Department; role: UserRole
  active: boolean; language: UiLanguage; created_at: string; updated_at: string
}
export type AircraftType = { id: string; code: string; name: string; active: boolean }
export type TypeAssignment = { user_id: string; aircraft_type_id: string; department: Department; created_at: string }
export type Deputy = {
  id: string; user_id: string; deputy_user_id: string; valid_from: string; valid_to: string
  created_by: string | null; created_at: string
}
export type Company = { id: string; name: string; active: boolean; created_at: string }
export type Trainee = {
  id: string; name: string; date_of_birth: string | null; email: string | null
  company_id: string | null; active: boolean; created_at: string
}
export type Checkpoint = {
  id: string; code: string; gate_no: 1 | 2 | 3; department: Department; label_de: string; label_en: string
  mandatory: boolean; four_eyes: boolean; evidence: string | null; deadline_days: number | null
  deadline_anchor: 'course_start' | 'enquiry_date' | 'course_end'; requires_gate_complete: boolean
  aircraft_type_filter: string[] | null; sort_order: number; active: boolean; created_at: string; updated_at: string
}
export type Case = {
  id: string; case_number: string; status: CaseStatus; trainee_id: string; company_id: string
  aircraft_type_id: string; course_type: string; enquiry_date: string; course_start: string | null
  course_end: string | null; instructor: string | null; examiner: string | null; fstd_slot: string | null
  closed_reason: string | null; created_by: string | null; created_at: string; updated_at: string
}
export type CaseAssignment = {
  case_id: string; department: Department; user_id: string | null; assigned_at: string | null
  pool_since: string; stale_notified_at: string | null
}
export type Gate = { case_id: string; gate_no: 1 | 2 | 3; status: GateState; released_by: string | null; released_at: string | null }
export type CaseCheckpoint = {
  id: string; case_id: string; checkpoint_id: string; status: CheckpointState; due_at: string | null
  completed_by: string | null; completed_at: string | null; verified_by: string | null; verified_at: string | null
  note: string | null
}
export type CaseException = {
  id: string; case_id: string; gate_no: 1 | 2 | 3; checkpoint_id: string; reason: string; status: ExceptionState
  requested_by: string; requested_at: string; decided_by: string | null; decided_at: string | null
  decision_note: string | null
}
export type Notification = {
  id: string; user_id: string; case_id: string | null; type: NotificationType; payload: Json; due_at: string
  sent_at: string | null; read_at: string | null; escalated: boolean; email_status: EmailState
  email_error: string | null; created_at: string
}
export type Message = {
  id: string; scope: MessageScope; scope_id: string; user_id: string; body: string
  checkpoint_id: string | null; created_at: string; edited_at: string | null
}
export type MessageEdit = { id: string; message_id: string; previous_body: string; edited_by: string; edited_at: string }
export type MessageMention = { message_id: string; user_id: string | null; department: Department | null }
export type ThreadRead = { user_id: string; scope: MessageScope; scope_id: string; last_read_at: string }
export type AuditEntry = {
  id: number; user_id: string | null; case_id: string | null; entity: string; entity_id: string; action: string
  old_value: Json | null; new_value: Json | null; reason: string | null; created_at: string
}
export type Setting = { key: string; value: Json; description: string | null; updated_by: string | null; updated_at: string }
export type ChangelogEntry = { version: string; released_on: string; notes_de: string; notes_en: string }

export type CaseOverview = Case & {
  trainee_name: string; trainee_dob: string | null; company_name: string; aircraft_type: string
  sales_user_id: string | null; sales_user_name: string | null
  training_admin_user_id: string | null; training_admin_user_name: string | null
  ato_user_id: string | null; ato_user_name: string | null
  gate1_state: DisplayState | null; gate2_state: DisplayState | null; gate3_state: DisplayState | null
  current_gate: 1 | 2 | 3 | null
  next_checkpoint_id: string | null; next_task_de: string | null; next_task_en: string | null
  next_task_department: Department | null; next_task_due_at: string | null
  is_overdue: boolean; has_exception: boolean; has_open_exception_request: boolean; has_pool_entry: boolean
  display_state: DisplayState
}
export type PoolEntry = {
  department: Department; pool_since: string; business_days_in_pool: number; is_stale: boolean
  case_id: string; case_number: string; status: CaseStatus; trainee_name: string; company_name: string
  aircraft_type: string; aircraft_type_id: string; course_type: string; course_start: string | null
  next_task_de: string | null; next_task_en: string | null; next_task_department: Department | null
  next_task_due_at: string | null; display_state: DisplayState
}
export type CaseCheckpointView = CaseCheckpoint & {
  code: string; gate_no: 1 | 2 | 3; department: Department; label_de: string; label_en: string
  mandatory: boolean; four_eyes: boolean; evidence: string | null; requires_gate_complete: boolean
  sort_order: number; has_exception: boolean; exception_requested: boolean; is_overdue: boolean
  display_state: DisplayState
}
export type GateView = Gate & {
  release_department: Department; open_mandatory: number; total_mandatory: number
  is_overdue: boolean | null; display_state: DisplayState
}
export type Pipeline = {
  enquiry: number; gate1_blocking: number; booked: number; gate2_blocking: number; in_progress: number
  gate3_blocking: number; completed: number; open_cases: number; overdue_cases: number; pool_cases: number
  completed_30d: number; exceptions_30d: number; gate3_warnings: number
}
export type ExceptionStat = {
  department: Department; aircraft_type: string; checkpoint_code: string; label_de: string; label_en: string
  approved: number; rejected: number; pending: number; last_requested_at: string | null
}
export type GateLeadTime = {
  case_id: string; case_number: string; aircraft_type: string
  days_to_gate1: number | null; days_gate1_to_gate2: number | null; days_gate2_to_gate3: number | null
}
export type UnreadThread = { scope: MessageScope; scope_id: string; unread: number }

export type Database = {
  public: {
    Tables: {
      users: Table<User>
      aircraft_types: Table<AircraftType>
      type_assignments: Table<TypeAssignment>
      deputies: Table<Deputy>
      companies: Table<Company>
      trainees: Table<Trainee>
      checkpoints: Table<Checkpoint>
      cases: Table<Case>
      case_assignments: Table<CaseAssignment>
      gates: Table<Gate>
      case_checkpoints: Table<CaseCheckpoint>
      exceptions: Table<CaseException>
      notifications: Table<Notification>
      messages: Table<Message>
      message_edits: Table<MessageEdit>
      message_mentions: Table<MessageMention>
      thread_reads: Table<ThreadRead>
      audit_log: Table<AuditEntry>
      settings: Table<Setting>
      changelog: Table<ChangelogEntry>
    }
    Views: {
      v_cases: View<CaseOverview>
      v_pool: View<PoolEntry>
      v_case_checkpoints: View<CaseCheckpointView>
      v_gates: View<GateView>
      v_pipeline: View<Pipeline>
      v_exception_stats: View<ExceptionStat>
      v_gate_lead_times: View<GateLeadTime>
      v_unread_threads: View<UnreadThread>
    }
    Functions: {
      create_case: {
        Args: {
          p_trainee_id: string; p_company_id: string; p_aircraft_type_id: string; p_course_type: string
          p_enquiry_date?: string; p_course_start?: string | null; p_course_end?: string | null
        }
        Returns: string
      }
      claim_case: { Args: { p_case_id: string }; Returns: undefined }
      assign_case: { Args: { p_case_id: string; p_department: Department; p_user_id: string }; Returns: undefined }
      release_to_pool: { Args: { p_case_id: string; p_department: Department }; Returns: undefined }
      complete_checkpoint: { Args: { p_case_checkpoint_id: string; p_note?: string | null }; Returns: CaseCheckpoint }
      verify_checkpoint: { Args: { p_case_checkpoint_id: string; p_note?: string | null }; Returns: CaseCheckpoint }
      reset_checkpoint: { Args: { p_case_checkpoint_id: string; p_reason: string }; Returns: CaseCheckpoint }
      release_gate: { Args: { p_case_id: string; p_gate_no: 1 | 2 | 3 }; Returns: Gate }
      discard_case: { Args: { p_case_id: string; p_reason: string }; Returns: undefined }
      request_exception: { Args: { p_case_id: string; p_checkpoint_id: string; p_reason: string }; Returns: CaseException }
      decide_exception: { Args: { p_exception_id: string; p_approve: boolean; p_note?: string | null }; Returns: CaseException }
      copy_course_fields: { Args: { p_source_case_id: string }; Returns: number }
      post_message: {
        Args: {
          p_scope: MessageScope; p_scope_id: string; p_body: string; p_checkpoint_id?: string | null
          p_mention_user_ids?: string[]; p_mention_departments?: Department[]
        }
        Returns: Message
      }
      mark_thread_read: { Args: { p_scope: MessageScope; p_scope_id: string }; Returns: undefined }
      mark_notifications_read: { Args: { p_ids: string[] }; Returns: number }
      add_business_days: { Args: { p_date: string; p_days: number }; Returns: string }
    }
    Enums: {
      department: Department
      user_role: UserRole
      ui_language: UiLanguage
      case_status: CaseStatus
      checkpoint_state: CheckpointState
      gate_state: GateState
      exception_state: ExceptionState
      message_scope: MessageScope
      notification_type: NotificationType
      email_state: EmailState
    }
    CompositeTypes: Record<string, never>
  }
}
