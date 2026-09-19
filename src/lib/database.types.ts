// Typisierung des Supabase-Schemas (Schema 1.0.0). Manuell gepflegt und mit
// den Migrationen in supabase/migrations abgeglichen. Kann später durch
// `supabase gen types typescript` ersetzt werden.

// Zwei Zugänge, entschieden am 19.09.2026: 'team' darf alles, 'viewer' liest.
// Personen ohne eigene Anmeldung tragen role = null.
export type UserRole = 'team' | 'viewer'
export type UiLanguage = 'de' | 'en'
export type ProjectStatus =
  | 'not_started' | 'started' | 'on_track' | 'at_risk' | 'delayed' | 'cancelled' | 'completed'
export type Health = 'green' | 'amber' | 'red'
export type TaskStatus = 'not_started' | 'in_progress' | 'blocked' | 'completed' | 'cancelled'
export type Priority = 'low' | 'medium' | 'high' | 'critical'
export type MilestoneStatus = 'planned' | 'in_progress' | 'completed' | 'delayed'
export type RiskStatus = 'open' | 'monitoring' | 'mitigated' | 'closed' | 'accepted'
export type IssueStatus = 'open' | 'in_progress' | 'blocked' | 'resolved' | 'closed'
export type ProgressMode = 'manual' | 'derived'
export type DocumentKind = 'file' | 'link'
export type ScanState = 'pending' | 'clean' | 'infected'
export type RaciLetter = 'R' | 'A' | 'C' | 'I'
export type EntityType =
  | 'project' | 'workstream' | 'task' | 'milestone' | 'risk' | 'issue' | 'decision' | 'document'
export type NotificationKind =
  | 'assigned' | 'mention' | 'comment' | 'due_soon' | 'overdue'
  | 'status_change' | 'milestone' | 'risk_critical' | 'approval'
export type EmailState = 'pending' | 'sent' | 'failed' | 'skipped'

type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

type Table<Row, Insert = Partial<Row>, Update = Partial<Row>> = {
  Row: Row
  Insert: Insert
  Update: Update
  Relationships: []
}
type View<Row> = { Row: Row; Relationships: [] }

export type User = {
  id: string; auth_user_id: string | null
  name: string; email: string; job_title: string | null
  role: UserRole | null
  active: boolean; language: UiLanguage
  created_at: string; updated_at: string
}

// Eine Zeile der Gantt-Darstellung (pcc.v_gantt): Teilprojekt, Aufgabe,
// Teilaufgabe oder Meilenstein — in dieser Reihenfolge zu zeichnen.
export type GanttRow = {
  project_id: string; kind: 'workstream' | 'task' | 'milestone'
  id: string; parent_id: string | null; workstream_id: string | null
  label: string; ref: string | null; person_id: string | null
  start_date: string | null; due_date: string | null
  task_status: TaskStatus | null; milestone_status: MilestoneStatus | null
  progress: number; open_count: number; sort_order: number; depth: number
}

export type Project = {
  id: string; key: string; name: string; description: string | null
  objectives: string | null; scope: string | null
  status: ProjectStatus; pm_user_id: string; sponsor_user_id: string | null
  start_date: string | null; target_end_date: string | null; actual_end_date: string | null
  progress_mode: ProgressMode; progress_manual: number; template_id: string | null
  version_major: number; version_minor: number
  archived_at: string | null; archived_by: string | null
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type ProjectMember = {
  project_id: string; user_id: string; project_role: string
  responsibilities: string | null; created_at: string; created_by: string | null
}

export type Workstream = {
  id: string; project_id: string; name: string; description: string | null
  owner_user_id: string | null; sort_order: number; completed_at: string | null
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type Task = {
  id: string; project_id: string; workstream_id: string | null; parent_task_id: string | null
  ref: string; title: string; description: string | null
  assignee_user_id: string | null; priority: Priority; status: TaskStatus
  start_date: string | null; due_date: string | null; completed_at: string | null
  progress: number; progress_mode: ProgressMode; sort_order: number
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type Milestone = {
  id: string; project_id: string; workstream_id: string | null; ref: string
  name: string; description: string | null; due_date: string; baseline_date: string | null
  owner_user_id: string | null; status: MilestoneStatus
  depends_on_milestone_id: string | null; completed_at: string | null; notes: string | null
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type Risk = {
  id: string; project_id: string; ref: string; title: string; description: string | null
  category: string | null; probability: number; impact: number
  /** Generierte Spalte: probability * impact. Nie im Client rechnen. */
  score: number
  owner_user_id: string | null; mitigation: string | null; contingency: string | null
  due_date: string | null; status: RiskStatus; closed_at: string | null
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type Issue = {
  id: string; project_id: string; ref: string; title: string; description: string | null
  owner_user_id: string | null; priority: Priority; status: IssueStatus
  due_date: string | null; resolution: string | null; resolved_at: string | null
  risk_id: string | null
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type Decision = {
  id: string; project_id: string; ref: string; decided_on: string
  topic: string; decision: string; maker_user_id: string | null; participants: string[]
  rationale: string | null; impact: string | null; task_id: string | null
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type ProjectDocument = {
  id: string; project_id: string; entity_type: EntityType; entity_id: string | null
  title: string; description: string | null; kind: DocumentKind
  storage_path: string | null; external_url: string | null
  mime_type: string | null; size_bytes: number | null; scan_state: ScanState
  version: number; supersedes_id: string | null; owner_user_id: string | null
  deleted_at: string | null; deleted_by: string | null; deleted_reason: string | null
  created_at: string; created_by: string | null; updated_at: string; updated_by: string | null
}

export type Comment = {
  id: string; project_id: string; entity_type: EntityType; entity_id: string
  user_id: string; body: string; edited_at: string | null
  deleted_at: string | null; deleted_by: string | null; deleted_reason: string | null
  created_at: string
}

export type Notification = {
  id: string; user_id: string; project_id: string | null; kind: NotificationKind
  entity_type: EntityType | null; entity_id: string | null
  title: string; body: string | null; read_at: string | null
  email_state: EmailState; created_at: string
}

export type ProjectVersion = {
  id: string; project_id: string; version: string; trigger_code: string | null
  summary: string; created_by: string | null; created_at: string
}

export type AuditEntry = {
  id: number; user_id: string | null; project_id: string | null
  entity: string; entity_id: string; action: string
  old_value: Json | null; new_value: Json | null; reason: string | null; created_at: string
}

/** Zeile aus pcc.v_projects: Projekt samt gerechneter Kennzahlen. */
export type ProjectOverview = {
  id: string; key: string; name: string; description: string | null
  objectives: string | null; scope: string | null; status: ProjectStatus
  pm_user_id: string; pm_name: string | null; sponsor_user_id: string | null
  start_date: string | null; target_end_date: string | null; actual_end_date: string | null
  archived: boolean; version: string
  progress: number; health: Health
  task_count: number; overdue_tasks: number
  open_risks: number; critical_risks: number; open_issues: number
  team_size: number; next_milestone_date: string | null; next_milestone: string | null
  created_at: string; updated_at: string
}

/** Zeile aus pcc.v_dashboard: eine Zeile über alle sichtbaren Projekte. */
export type DashboardTotals = {
  projects_total: number; projects_active: number
  projects_on_track: number; projects_at_risk: number; projects_delayed: number
  projects_completed: number; projects_red: number; projects_amber: number
  open_risks: number; critical_risks: number; open_issues: number; overdue_tasks: number
}

export type Database = {
  public: {
    Tables: {
      users: Table<User>
      audit_log: Table<AuditEntry>
    }
    Views: Record<string, never>
    Functions: Record<string, never>
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
  pcc: {
    Tables: {
      projects: Table<Project>
      project_members: Table<ProjectMember>
      workstreams: Table<Workstream>
      tasks: Table<Task>
      milestones: Table<Milestone>
      risks: Table<Risk>
      issues: Table<Issue>
      decisions: Table<Decision>
      documents: Table<ProjectDocument>
      comments: Table<Comment>
      notifications: Table<Notification>
      project_versions: Table<ProjectVersion>
    }
    Views: {
      v_projects: View<ProjectOverview>
      v_dashboard: View<DashboardTotals>
      v_gantt: View<GanttRow>
    }
    Functions: Record<string, never>
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}
