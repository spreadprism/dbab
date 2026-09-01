# dbab.nvim

> [!WARNING]
> **Disclaimer:** The original upstream repository has been deleted and now
> returns a **404**. This is a copy recovered from my local Nix store, preserved
> here for archival and continued use. It is not the official source and may not
> reflect any later changes the original author may have made.

A lightweight database client for Neovim. Query databases directly from your editor.

![dbab.nvim](./screenshots/main.png)

## Features

- **Multi-database support**: PostgreSQL, MySQL, MariaDB, SQLite
- **One tab per connection**: each connection gets its own Neovim tabpage, with its own editor, results and history
- **Flexible layout**: Choose from presets or define your own pane arrangement
- **Schema browser**: Navigate schemas, tables, and columns in sidebar
- **Query editor**: Write and execute SQL with syntax highlighting
- **Keyword casing**: SQL keywords are uppercased when you leave insert mode (treesitter-aware, so strings and identifiers are untouched)
- **Query history**: Track executed queries with timing, re-execute or load to editor
- **Multiple query tabs**: Work with multiple queries simultaneously
- **Save queries**: Store frequently used queries per connection
- **Result viewer**: Multiple display styles (table, json, vertical, markdown, raw) with type-aware highlighting
- **Sticky header**: Column names stay pinned while you scroll through results
- **Editable results**: edit cells in place and `:w` to generate, confirm and apply `UPDATE` and `DELETE` statements
- **Lifecycle hooks**: run a proxy or tunnel before a connection opens and tear it down when the tab closes

## Layout

### Classic (default)

![Classic Layout](./screenshots/layout-classic.png)

```
┌─────────────────────┬─────────────────────────────────────┐
│ Sidebar (20%)       │ Query Editor (80%)                  │
├─────────────────────┼─────────────────────────────────────┤
│ History (20%)       │ Result Viewer (80%)                 │
└─────────────────────┴─────────────────────────────────────┘
```

### Wide

![Wide Layout](./screenshots/layout-wide.png)

```
┌─────────────────────┬─────────────────────┬───────────────┐
│ Sidebar (33%)       │ Query Editor (34%)  │ History (33%) │
├───────────────────────────────────────────────────────────┤
│                    Result Viewer (100%)                   │
└───────────────────────────────────────────────────────────┘
```

## Requirements

- Neovim >= 0.9.0
- Database CLI tools:
  - `psql` for PostgreSQL
  - `mysql` for MySQL/MariaDB
  - `sqlite3` for SQLite
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [vim-dadbod](https://github.com/tpope/vim-dadbod) (optional: for `executor = "dadbod"`)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (optional: for async execution)

## Installation

### lazy.nvim

```lua
{
  "zerochae/dbab.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "nvim-lua/plenary.nvim",       -- Optional: for async execution
    "tpope/vim-dadbod",            -- Optional: for executor = "dadbod"
    "hrsh7th/nvim-cmp",            -- Optional: for nvim-cmp autocompletion
  },
  -- For blink.cmp, the source is included in this plugin (blink_dbab)
  config = function()
    require("dbab").setup({
      connections = {
        { name = "local", url = "postgres://user:pass@localhost:5432/mydb" },
        { name = "prod", url = "$DATABASE_URL" }, -- supports env vars
      },
    })
  end,
}
```

## Autocompletion (Optional)

### nvim-cmp

If you use `nvim-cmp`, add `dbab` to your sources to enable SQL autocompletion (tables, columns, keywords):

```lua
require("cmp").setup({
  sources = {
    { name = "dbab" },
    -- other sources...
  },
})
```

### blink.cmp

If you use `blink.cmp`, add `dbab` to your sources:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "snippets", "buffer", "dbab" },
    providers = {
      dbab = {
        name = "dbab",
        module = "blink_dbab",
      },
    },
  },
})
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:Dbab` | Pick a connection and open its workbench |
| `:Dbab <name>` | Open (or focus) the workbench for `<name>` |
| `:Dbab list` | List connections, marking the open ones |
| `:Dbab query <sql>` | Run SQL against the current workbench's connection |
| `:DbabClose [name]` | Close the named workbench, or the current one |
| `:DbabRestore` | Rebuild the current workbench's layout |

### Sidebar Keymaps

| Key | Action |
|-----|--------|
| `<CR>` / `o` | Toggle node / Open query (within the pinned connection) |
| `<Tab>` | Move to editor |
| `S` | Select table (SELECT *) |
| `i` | Insert table (INSERT template) |
| `d` | Delete saved query |
| `q` | Close |

### Editor Keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Execute query (whole buffer) |
| `<CR>` (visual) | Execute selected text only |
| `<C-s>` | Save query |
| `gt` / `gT` | Next / Previous tab |
| `<Leader>w` | Close tab |
| `<Tab>` | Move to result |
| `q` | Close |

### History Keymaps

| Key | Action |
|-----|--------|
| `<CR>` | Load or execute query (based on config) |
| `R` | Re-execute query immediately |
| `y` | Copy query to clipboard |
| `d` | Delete entry |
| `C` | Clear all history |
| `<Tab>` | Move to sidebar |
| `<S-Tab>` | Move to result |
| `q` | Close |

### Result Keymaps

| Key | Action |
|-----|--------|
| `y` | Yank current row as JSON |
| `Y` | Yank all rows as JSON |
| `:w` | Apply cell edits (asks for confirmation) |
| `<Tab>` | Move to sidebar |
| `<S-Tab>` | Move to editor |
| `q` | Close |

## Screenshots

### Schema Browser
![Schema Browser](./screenshots/sidebar.png)

### Query Result with Type Highlighting
![Result Viewer](./screenshots/result.png)

### Query History
![Query History](./screenshots/history.png)

## Connection hooks

dbab can run hooks around a workbench's connection lifecycle. Four events fire when opening or closing a connection:

- `pre_open` — before the connection is opened / the tab is built. May refuse, which aborts the open.
- `post_open` — after the workbench is built.
- `pre_close` — before the workbench is torn down.
- `post_close` — after the workbench is torn down.

The motivating use case is an SSH tunnel or cloud SQL proxy that must be up before the first query and torn down when the tab goes away.

### Configuration

Hooks can be set globally under `hooks = { ... }` in `setup()`, and/or per connection under a connection's `hooks = { ... }` key. Global hooks run first, then the connection's own. Each event accepts a single function or a list of functions, run in order.

```lua
require("dbab").setup({
  connections = {
    {
      name = "prod",
      url = "postgres://localhost:5433/app",
      hooks = {
        -- Asynchronous: declare a second parameter and call it when ready.
        pre_open = function(ctx, done)
          local task = require("overseer").new_task({
            cmd = { "cloud-sql-proxy", "my-project:region:instance", "--port", "5433" },
          })
          task:start()
          vim.defer_fn(function() done(true) end, 2000)
        end,
        post_close = function(ctx)
          vim.fn.system({ "pkill", "-f", "cloud-sql-proxy" })
        end,
      },
    },
  },
  hooks = {
    -- Runs for every connection, before the per-connection hooks.
    post_open = function(ctx)
      vim.notify("dbab: opened " .. ctx.conn_name)
    end,
  },
})
```

### Hook Signature

Hooks can be synchronous or asynchronous:

- **Synchronous**: `function(ctx)` — runs immediately
- **Asynchronous**: `function(ctx, done)` — must call `done(true)` to continue or `done(false, "reason")` to refuse

Only `pre_open` can refuse. A synchronous hook can refuse by returning `false`, and an error raised in `pre_open` counts as a refusal. When a hook refuses, the workbench is not opened.

### Context

The `ctx` parameter is a table with:

| Field | Type | Present | Description |
|-------|------|---------|-------------|
| `conn_name` | string | always | Connection name |
| `url` | string | always | Resolved database URL |
| `db_type` | string | always | Database type (postgres, mysql, mariadb, sqlite) |
| `event` | string | always | Event name (pre_open, post_open, pre_close, post_close) |
| `workbench` | object | post_open, close events | The workbench object |

### Rules

- Only `pre_open` can refuse. A synchronous hook can also refuse by returning `false`, and an error raised in `pre_open` counts as a refusal. When it refuses, the workbench is not opened.
- Close hooks cannot veto — closing must always be possible. A failing close hook is reported and the teardown continues.
- Hooks do NOT re-run when you focus an already-open workbench; they only fire on a real open.
- The close hooks run on every teardown path: `:DbabClose`, `:tabclose`, and closing the sidebar window. They run exactly once.

## Editing results

Results from simple single-table queries can be edited directly in the result pane. After making changes, press `:w` to confirm and apply `UPDATE` and `DELETE` statements to the database.

### Editability Requirements

A result is editable only if ALL of these conditions hold:

- a single `FROM <table>` with no join of any kind
- no GROUP BY, HAVING, DISTINCT, UNION, INTERSECT, EXCEPT, CTE, window function or aggregate
- no subquery in FROM
- the select list is `*` or plain column references (no expressions, aliases or casts)
- the table has a primary key, and every key column is present in the result

The winbar shows an "editable" indicator when editing is allowed, or the reason why a result is read-only (e.g., "query aggregates rows", "table has no primary key").

### Workflow

1. Execute a qualifying query
2. Edit cell values in place using ordinary Vim motions
3. Press `:w` to apply the changes
4. A centred floating window appears showing the generated SQL with syntax highlighting. Confirm with a single keypress: `y`, `Y`, `o`, or `O` to apply; `n`, `N`, `q`, `<Esc>`, or `<C-c>` to cancel. Leaving the window also cancels.
5. On confirmation, the statements run behind a one-row guard and the original query is re-run

### Editing Rules and Round-Trip Caveats

- The exact unquoted text `NULL` means SQL NULL. A literal string 'NULL' cannot be typed into the grid.
- Padding is stripped on read, so a value cannot end in a space.
- One UPDATE is generated per edited row, with a multi-column SET.
- The WHERE clause always uses the row's ORIGINAL key value, so editing a key column works.
- Deleting a line generates a `DELETE FROM <table> WHERE <primary key> = <original value>;` statement, subject to the same one-row guard as `UPDATE`. Deletes and edits can be combined in a single write; `DELETE` statements are listed first in the confirmation.
- Adding a line, or replacing/emptying a line in place, is refused — re-run the query and edit cells in place.
- If the row no longer matches exactly once (it changed or was deleted behind your back) the write is aborted and rolled back; nothing is written.

## Configuration

```lua
require("dbab").setup({
  connections = {
    { name = "local", url = "postgres://localhost/mydb" },
  },
  executor = "cli",    -- "cli" (self-contained) | "dadbod" (requires vim-dadbod)
  layout = "classic",  -- "classic" | "wide" | custom layout table
  sidebar = {
    width = 0.2,
    use_brand_icon = false,   -- true: per-DB icons, false: generic db icon
    use_brand_color = false,  -- true: per-DB brand colors, false: single color (Number)
    show_brand_name = false,  -- true: show [postgres] label, false: icon + name only
    show_system_schemas = true,
  },
    editor = {
      show_tabbar = true,       -- show tab bar above editor
      upper_keywords = true,    -- uppercase SQL keywords when leaving insert mode
    },
  result = {
    max_width = 120,
    max_height = 20,
    show_line_number = true,
    header_align = "fit",     -- "fit" or "full"
    style = "table",          -- "table", "json", "raw", "vertical", "markdown"
    sticky_header = true,     -- Pin column header while scrolling (table style)
    focus_on_execute = false, -- Move cursor to result pane after running a query
  },
  history = {
    width = 0.2,
    style = "compact",        -- "compact" or "detailed"
    max_entries = 100,
    on_select = "execute",    -- "execute" or "load"
    persist = true,
    filter_by_connection = true,
    query_display = "auto",   -- "short", "full", or "auto"
    short_hints = { "where", "join", "order", "group", "limit" },
  },
  keymaps = {
    open = "<Leader>db",
    execute = "<CR>",
    close = "q",
    sidebar = {
      toggle_expand = { "<CR>", "o" },
      refresh = "R",
      rename = "r",
      new_query = "n",
      copy_name = "y",
      insert_template = "i",
      delete = "d",
      copy_query = "c",
      paste_query = "p",
      to_editor = "<Tab>",
      to_history = "<S-Tab>",
    },
    history = {
      select = "<CR>",
      execute = "R",
      copy = "y",
      delete = "d",
      clear = "C",
      to_sidebar = "<Tab>",
      to_result = "<S-Tab>",
    },
    editor = {
      execute_visual = "<CR>",
      execute_insert = "<C-CR>",
      execute_leader = "<Leader>r",
      save = "<C-s>",
      next_tab = "gt",
      prev_tab = "gT",
      close_tab = "<Leader>w",
      to_result = "<Tab>",
      to_sidebar = "<S-Tab>",
    },
    result = {
      yank_row = "y",
      yank_all = "Y",
      to_sidebar = "<Tab>",
      to_editor = "<S-Tab>",
    },
  },
  highlights = {
    -- Override any Dbab highlight group
    -- DbabHeader = { bg = "#ff6600", fg = "#000000" },
  },
})
```

### Layout Presets

| Preset | Description |
|--------|-------------|
| `"classic"` | 4-pane layout (sidebar 20%, history 20%) |
| `"wide"` | 3-column top + full-width bottom (sidebar 33%, history 33%) |

### Custom Layout

Define your own pane arrangement:

```lua
-- No history panel
layout = {
  { "sidebar", "editor" },
  { "result" },
}

-- Editor on the left
layout = {
  { "editor", "sidebar" },
  { "result", "history" },
}
```

Components: `"sidebar"`, `"editor"`, `"history"`, `"result"` (editor and result are required)

### Result Styles

Configure with `result.style`:

| Style | Description |
|-------|-------------|
| `"table"` | Table with zebra striping and type-aware highlighting (default) |
| `"json"` | JSON format with Treesitter syntax highlighting |
| `"vertical"` | One record per block, column names on the left (like `psql \x`) |
| `"markdown"` | Markdown table with Treesitter syntax highlighting |
| `"raw"` | Unprocessed CLI output |

```lua
result = {
  style = "vertical",
},
```

#### NULL vs empty string

The table style distinguishes a SQL `NULL` from an empty string:

| Value | Rendered | Highlight |
|-------|----------|-----------|
| `NULL` | `NULL` | `DbabNull` |
| `''` | *(blank)* | `DbabString` |
| `'NULL'` (a string) | `NULL` | `DbabString` |

dbab asks the client for a null sentinel (`psql --pset=null=\N`,
`sqlite3 -nullvalue \N`) so the two can be told apart. Two caveats:

- **MySQL** has no equivalent option. In batch mode it prints `NULL` for a real
  null, so a literal `'NULL'` string is indistinguishable from one.
- A value that is exactly `\N` is read as NULL on PostgreSQL and SQLite.

#### table

![style-table](./screenshots/result.png)


#### raw

![style-raw](./screenshots/style-raw.png)

#### json

![style-json](./screenshots/style-json.png)

#### vertical

![style-vertical](./screenshots/style-vertical.png)

#### markdown

![style-markdown](./screenshots/style-markdown.png)

### History Styles

Configure with `history.style`:

| Style | Description |
|-------|-------------|
| `"compact"` | One line per entry with verb, target, hints (default) |
| `"detailed"` | Multi-line: full query with syntax highlighting + metadata below |

```lua
history = {
  style = "detailed",
},
```

### Sidebar Display Options

Control how database connections appear in the sidebar:

```lua
sidebar = {
  use_brand_icon = false,   -- default
  use_brand_color = false,  -- default
  show_brand_name = false,  -- default
},
```

| Option | `false` (default) | `true` |
|--------|-------------------|--------|
| `use_brand_icon` | Generic DB icon for all connections | Per-DB brand icons (PostgreSQL, MySQL, etc.) |
| `use_brand_color` | Single color (`Number` highlight) | Per-DB brand colors (blue, red, green, etc.) |
| `show_brand_name` | `icon my_db` | `icon [postgres] my_db` |

## Highlight Groups

All highlight groups can be overridden by defining them before `setup()`.
Groups marked with **(computed)** are always recalculated based on your colorscheme.

### Result

| Group | Default | Description |
|-------|---------|-------------|
| `DbabRowOdd` | **(computed)** | Odd row background |
| `DbabRowEven` | **(computed)** | Even row background |
| `DbabHeader` | **(computed)** | Result header (from `Function` fg) |
| `DbabSeparator` | **(computed)** | Column separators (`Comment` fg, never italic) |
| `DbabConfirmPrompt` | `Question` | Prompt line in the write-confirmation float |
| `DbabCellActive` | `CursorLine` | Active cell |

### Window

| Group | Default | Description |
|-------|---------|-------------|
| `DbabFloat` | `NormalFloat` | Float window background |
| `DbabBorder` | `WinSeparator` | Window border |
| `DbabTitle` | `Title` | Window title |

### Data Types

| Group | Default | Description |
|-------|---------|-------------|
| `DbabNull` | `Comment` | NULL values |
| `DbabNumber` | `Number` | Numeric values |
| `DbabString` | `Normal` | String values |
| `DbabBoolean` | `Boolean` | Boolean values |
| `DbabDateTime` | `Special` | Date/time values |
| `DbabUuid` | `Constant` | UUID values |
| `DbabJson` | `Function` | JSON values |

### Schema

| Group | Default | Description |
|-------|---------|-------------|
| `DbabTable` | `Type` | Table names |
| `DbabKey` | `Keyword` | Key names |
| `DbabPK` | `ErrorMsg` | Primary key (bold) |
| `DbabFK` | `Function` | Foreign key (bold) |

### Sidebar

| Group | Default | Description |
|-------|---------|-------------|
| `DbabIconDb` | `Number` | Default DB icon color (`use_brand_color = false`) |
| `DbabIconPostgres` | `fg=#4169E1` | PostgreSQL brand color (bold) |
| `DbabIconMysql` | `fg=#4479A1` | MySQL brand color (bold) |
| `DbabIconMariadb` | `fg=#003545` | MariaDB brand color (bold) |
| `DbabIconSqlite` | `fg=#003B57` | SQLite brand color (bold) |
| `DbabIconRedis` | `fg=#FF4438` | Redis brand color (bold) |
| `DbabIconMongodb` | `fg=#47A248` | MongoDB brand color (bold) |
| `DbabSidebarIconConnection` | `Number` | Connection icon |
| `DbabSidebarIconActive` | `String` | Active connection icon |
| `DbabSidebarIconNewQuery` | `Function` | New query icon |
| `DbabSidebarIconBuffers` | `Function` | Buffers icon |
| `DbabSidebarIconSaved` | `Keyword` | Saved queries icon |
| `DbabSidebarIconSchemas` | `Special` | Schemas icon |
| `DbabSidebarIconSchema` | `Type` | Schema icon |
| `DbabSidebarIconTable` | `Type` | Table icon |
| `DbabSidebarIconColumn` | `Function` | Column icon |
| `DbabSidebarIconPK` | `ErrorMsg` | Primary key icon |
| `DbabSidebarText` | `Normal` | Default text |
| `DbabSidebarTextActive` | `String` | Active item text (bold) |
| `DbabSidebarType` | `Comment` | Type annotation |

### History

| Group | Default | Description |
|-------|---------|-------------|
| `DbabHistoryHeader` | `Title` | Section header (bold) |
| `DbabHistoryRowOdd` | **(computed)** | Odd row background |
| `DbabHistoryRowEven` | **(computed)** | Even row background |
| `DbabHistoryTime` | `Comment` | Timestamp |
| `DbabHistoryVerb` | `Keyword` | SQL verb |
| `DbabHistoryTarget` | `Type` | Target table name |
| `DbabHistoryDuration` | `Number` | Execution duration |
| `DbabHistoryConnName` | `Normal` | Connection name |
| `DbabHistorySelect` | `Function` | SELECT queries |
| `DbabHistoryInsert` | `String` | INSERT queries |
| `DbabHistoryUpdate` | `Type` | UPDATE queries |
| `DbabHistoryDelete` | `ErrorMsg` | DELETE queries |
| `DbabHistoryCreate` | `String` | CREATE statements |
| `DbabHistoryDrop` | `ErrorMsg` | DROP statements |
| `DbabHistoryAlter` | `Special` | ALTER statements |
| `DbabHistoryTruncate` | `WarningMsg` | TRUNCATE statements |

Hint badges (compact mode):

| Group | Default | Description |
|-------|---------|-------------|
| `DbabHistoryHintWhere` | `WarningMsg` | WHERE clause |
| `DbabHistoryHintJoin` | `Special` | JOIN clause |
| `DbabHistoryHintOrder` | `Keyword` | ORDER BY |
| `DbabHistoryHintGroup` | `Type` | GROUP BY |
| `DbabHistoryHintLimit` | `Number` | LIMIT |

### Tab Bar

| Group | Default | Description |
|-------|---------|-------------|
| `DbabTabActive` | `bg=#3a3a4a` | Active tab (bold) |
| `DbabTabActiveIcon` | `bg=#3a3a4a fg=#a6e3a1` | Active tab icon |
| `DbabTabInactive` | `Comment` | Inactive tab |
| `DbabTabInactiveIcon` | `Comment` | Inactive tab icon |
| `DbabTabModified` | `WarningMsg` | Modified indicator |
| `DbabTabIconSaved` | `String` | Saved query icon |
| `DbabTabIconUnsaved` | `Function` | Unsaved query icon |
| `DbabTabbarBg` | `Normal` | Tab bar background |

### Customization

Override highlights via `setup()`:

```lua
require("dbab").setup({
  highlights = {
    DbabHeader = { bg = "#ff6600", fg = "#000000" },
    DbabNull = { fg = "#555555", italic = true },
  },
})
```

## Connection URL Format

```
postgres://user:password@host:port/database
mysql://user:password@host:port/database
mariadb://user:password@host:port/database
sqlite:///path/to/database.db
```

Environment variables are supported: `$DATABASE_URL` or `${DATABASE_URL}`

## Acknowledgements

This project was inspired by excellent existing plugins:

- [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui): The classic DB UI for Vim/Neovim.
- [nvim-dbee](https://github.com/kndndrj/nvim-dbee): A modern approach to DB client in Neovim.

`dbab.nvim` aims to provide a lightweight, self-contained alternative with a modern Lua-based UI. It can optionally integrate with [vim-dadbod](https://github.com/tpope/vim-dadbod) via `executor = "dadbod"`.

## License

MIT
