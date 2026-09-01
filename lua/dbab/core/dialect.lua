--- Turning values back into SQL text.
---
--- With a CLI subprocess there are no bind parameters, so statements are built
--- by concatenation -- injection by construction. Two things keep that
--- defensible: the user is shown the exact statement and must confirm it, and
--- the write is wrapped so it cannot touch more than one row.
---@class Dbab.Dialect
local M = {}

---@param db_type string
---@return string
local function quote_char(db_type)
	return db_type == "mysql" and "`" or '"'
end

--- Quote an identifier.
---
--- Always, never conditionally: an unquoted identifier is case-folded (postgres
--- lowercases, mysql may not) and a column named `order` is a syntax error.
--- Escaping is by doubling the quote character.
---@param name string
---@param db_type string
---@return string
function M.identifier(name, db_type)
	local q = quote_char(db_type)

	return q .. tostring(name):gsub(q, q .. q) .. q
end

--- Quote a literal.
---
--- Postgres and SQLite need single quotes doubled and nothing else (postgres
--- with `standard_conforming_strings`, on by default since 9.1). MySQL has
--- backslash escapes active by default, so the backslash must be escaped too.
---@param value any
---@param db_type string
---@return string
function M.literal(value, db_type)
	if value == nil or value == vim.NIL then
		return "NULL"
	end

	local text = tostring(value)

	if db_type == "mysql" then
		text = text:gsub("\\", "\\\\")
	end

	return "'" .. text:gsub("'", "''") .. "'"
end

--- A qualified table reference.
---@param table_name string
---@param schema string|nil
---@param db_type string
---@return string
function M.table_ref(table_name, schema, db_type)
	if schema and schema ~= "" then
		return M.identifier(schema, db_type) .. "." .. M.identifier(table_name, db_type)
	end

	return M.identifier(table_name, db_type)
end

---@class Dbab.UpdateSpec
---@field table_name string
---@field schema string|nil
---@field sets {column: string, value: any}[]
---@field wheres {column: string, value: any}[]

--- One UPDATE per dirty row, with a multi-column SET.
---@param spec Dbab.UpdateSpec
---@param db_type string
---@return string
function M.update(spec, db_type)
	local sets = {}
	for _, set in ipairs(spec.sets) do
		table.insert(sets, ("%s = %s"):format(M.identifier(set.column, db_type), M.literal(set.value, db_type)))
	end

	local wheres = {}
	for _, where in ipairs(spec.wheres) do
		-- A primary key cannot be NULL, so `=` is always right here. Were that to
		-- change, this would need `IS NULL`.
		table.insert(wheres, ("%s = %s"):format(M.identifier(where.column, db_type), M.literal(where.value, db_type)))
	end

	return ("UPDATE %s SET %s WHERE %s;"):format(
		M.table_ref(spec.table_name, spec.schema, db_type),
		table.concat(sets, ", "),
		table.concat(wheres, " AND ")
	)
end

---@class Dbab.DeleteSpec
---@field table_name string
---@field schema string|nil
---@field wheres {column: string, value: any}[]

--- One DELETE per removed row.
---@param spec Dbab.DeleteSpec
---@param db_type string
---@return string
function M.delete(spec, db_type)
	local wheres = {}
	for _, where in ipairs(spec.wheres) do
		table.insert(wheres, ("%s = %s"):format(M.identifier(where.column, db_type), M.literal(where.value, db_type)))
	end

	return ("DELETE FROM %s WHERE %s;"):format(
		M.table_ref(spec.table_name, spec.schema, db_type),
		table.concat(wheres, " AND ")
	)
end

--- Wrap statements so they cannot commit unless each touches exactly one row.
---
--- If each statement were its own subprocess a transaction could not span calls
--- -- BEGIN in one process and COMMIT in another is two sessions, and the first
--- rolls back on exit. The guard is therefore a single payload sent in one
--- invocation.
---@param statements string[]
---@param db_type string
---@return string
function M.guard(statements, db_type)
	if #statements == 0 then
		return ""
	end

	if db_type == "postgres" then
		local body = {}
		for _, statement in ipairs(statements) do
			table.insert(body, "  " .. statement)
			table.insert(body, "  GET DIAGNOSTICS affected = ROW_COUNT;")
			table.insert(body, "  IF affected <> 1 THEN RAISE EXCEPTION 'dbab: expected 1 row, touched %', affected; END IF;")
		end

		-- RAISE EXCEPTION inside a DO block aborts the implicit transaction, so
		-- the update rolls back and psql exits non-zero.
		return table.concat({
			"DO $dbab$",
			"DECLARE affected integer;",
			"BEGIN",
			table.concat(body, "\n"),
			"END",
			"$dbab$;",
		}, "\n")
	end

	if db_type == "sqlite" then
		-- `RAISE()` is only legal inside a trigger program, so the abort is an
		-- integer overflow instead -- a runtime error, evaluated only when the
		-- row count is wrong. `.bail on` is essential: without it the client
		-- reports the error and then carries on to COMMIT the rest anyway.
		local body = { ".bail on", "BEGIN;" }
		for _, statement in ipairs(statements) do
			table.insert(body, statement)
			table.insert(body, "SELECT CASE WHEN changes() <> 1 THEN abs(-9223372036854775808) END;")
		end
		table.insert(body, "COMMIT;")

		return table.concat(body, "\n")
	end

	if db_type == "mysql" then
		-- MySQL has no anonymous blocks and `SIGNAL` is only legal inside a
		-- stored program. A subquery that returns two rows raises 1242 at
		-- *runtime*, and only when IF() takes the false branch -- unlike an
		-- unknown column, which MySQL resolves at parse time and would therefore
		-- fail even on success. The client stops on the error and the open
		-- transaction rolls back when the connection closes short of COMMIT.
		local body = { "START TRANSACTION;" }
		for _, statement in ipairs(statements) do
			table.insert(body, statement)
			table.insert(body, "SELECT IF(ROW_COUNT() = 1, 1, (SELECT 1 UNION ALL SELECT 2)) INTO @dbab_guard;")
		end
		table.insert(body, "COMMIT;")

		return table.concat(body, "\n")
	end

	return table.concat(statements, "\n")
end

return M
