-- Zext Scenario Hub: one row per stored share code.
CREATE TABLE IF NOT EXISTS codes (
    id          TEXT PRIMARY KEY,          -- the 7 characters after "ZX-"
    hash        TEXT NOT NULL UNIQUE,      -- sha-256 of the long code: the same code gets the same id
    code        TEXT NOT NULL,             -- the long code (WDS1....)
    name        TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    cards       INTEGER NOT NULL DEFAULT 0,
    things      INTEGER NOT NULL DEFAULT 0,
    uploader    TEXT NOT NULL,             -- sha-256 of the uploader's address and IP_SALT, for the hourly limit
    created_at  INTEGER NOT NULL           -- ms since 1970
);
CREATE INDEX IF NOT EXISTS codes_uploader ON codes (uploader, created_at);
