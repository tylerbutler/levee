-- Levee storage tables for PostgreSQL backend
-- Phase 1: Schema definition

-- Documents
CREATE TABLE IF NOT EXISTS documents (
  tenant_id TEXT NOT NULL,
  id TEXT NOT NULL,
  sequence_number INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, id)
);

-- Deltas (ordered by sequence number)
CREATE TABLE IF NOT EXISTS deltas (
  tenant_id TEXT NOT NULL,
  document_id TEXT NOT NULL,
  sequence_number INTEGER NOT NULL,
  client_id TEXT,
  client_sequence_number INTEGER NOT NULL,
  reference_sequence_number INTEGER NOT NULL,
  minimum_sequence_number INTEGER NOT NULL,
  op_type TEXT NOT NULL,
  contents JSONB,
  metadata JSONB,
  timestamp BIGINT NOT NULL,
  PRIMARY KEY (tenant_id, document_id, sequence_number)
);

-- Blobs (content-addressed)
CREATE TABLE IF NOT EXISTS blobs (
  tenant_id TEXT NOT NULL,
  sha TEXT NOT NULL,
  content BYTEA NOT NULL,
  size INTEGER NOT NULL,
  PRIMARY KEY (tenant_id, sha)
);

-- Trees
CREATE TABLE IF NOT EXISTS trees (
  tenant_id TEXT NOT NULL,
  sha TEXT NOT NULL,
  PRIMARY KEY (tenant_id, sha)
);

CREATE TABLE IF NOT EXISTS tree_entries (
  tenant_id TEXT NOT NULL,
  tree_sha TEXT NOT NULL,
  path TEXT NOT NULL,
  mode TEXT NOT NULL,
  sha TEXT NOT NULL,
  entry_type TEXT NOT NULL,
  PRIMARY KEY (tenant_id, tree_sha, path),
  FOREIGN KEY (tenant_id, tree_sha) REFERENCES trees(tenant_id, sha) ON DELETE CASCADE
);

-- Commits
CREATE TABLE IF NOT EXISTS commits (
  tenant_id TEXT NOT NULL,
  sha TEXT NOT NULL,
  tree_sha TEXT NOT NULL,
  parents TEXT[] NOT NULL DEFAULT '{}',
  message TEXT,
  author JSONB NOT NULL,
  committer JSONB NOT NULL,
  PRIMARY KEY (tenant_id, sha)
);

-- Refs
CREATE TABLE IF NOT EXISTS refs (
  tenant_id TEXT NOT NULL,
  ref_path TEXT NOT NULL,
  sha TEXT NOT NULL,
  PRIMARY KEY (tenant_id, ref_path)
);

-- Summaries (ordered by sequence number)
CREATE TABLE IF NOT EXISTS summaries (
  tenant_id TEXT NOT NULL,
  document_id TEXT NOT NULL,
  handle TEXT NOT NULL,
  sequence_number INTEGER NOT NULL,
  tree_sha TEXT NOT NULL,
  commit_sha TEXT,
  parent_handle TEXT,
  message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (tenant_id, document_id, sequence_number),
  UNIQUE (tenant_id, document_id, handle)
);
