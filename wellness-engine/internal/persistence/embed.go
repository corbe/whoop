// Embed the SQL migrations so the postgres adapter (and tests) can apply
// them without filesystem coupling. Package persistence is the embed owner
// because migrations live at internal/persistence/migrations.
package persistence

import "embed"

//go:embed migrations/*.sql
var MigrationsFS embed.FS
