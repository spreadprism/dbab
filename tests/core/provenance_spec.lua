local provenance = require("dbab.core.provenance")

describe("provenance", function()
	describe("analyze accepts", function()
		it("a plain select", function()
			local a = provenance.analyze("SELECT id, name FROM users")

			assert.is_true(a.editable)
			assert.are.equal("users", a.table_name)
			assert.are.same({ "id", "name" }, a.columns)
		end)

		it("a star select", function()
			local a = provenance.analyze("SELECT * FROM users;")

			assert.is_true(a.editable)
			assert.is_true(a.star)
			assert.are.equal("users", a.table_name)
		end)

		it("a schema-qualified table", function()
			local a = provenance.analyze("SELECT id FROM public.users")

			assert.is_true(a.editable)
			assert.are.equal("public", a.schema)
			assert.are.equal("users", a.table_name)
		end)

		it("a WHERE, ORDER BY and LIMIT", function()
			local a = provenance.analyze("SELECT id FROM users WHERE id > 3 ORDER BY id LIMIT 10")

			assert.is_true(a.editable)
			assert.are.equal("users", a.table_name)
		end)

		it("qualified column references", function()
			local a = provenance.analyze("SELECT users.id, users.name FROM users")

			assert.is_true(a.editable)
			assert.are.same({ "id", "name" }, a.columns)
		end)

		it("a string literal that merely contains a keyword", function()
			local a = provenance.analyze([[SELECT id FROM users WHERE name = 'inner join']])

			assert.is_true(a.editable)
			assert.are.equal("users", a.table_name)
		end)

		it("mixed case and extra whitespace", function()
			local a = provenance.analyze("  select   Id\n  from   Users  ")

			assert.is_true(a.editable)
			assert.are.equal("users", a.table_name)
		end)
	end)

	describe("analyze refuses", function()
		---@param query string
		---@param expected string
		local function refuses(query, expected)
			local a = provenance.analyze(query)
			assert.is_false(a.editable, "expected refusal for: " .. query)
			assert.is_not_nil(a.reason:find(expected, 1, true), ("reason %q lacks %q"):format(a.reason, expected))
		end

		it("a join", function()
			refuses("SELECT a.id FROM a JOIN b ON a.id = b.a_id", "joins")
		end)

		it("an old-style comma join", function()
			refuses("SELECT a.id FROM a, b", "joins")
		end)

		it("a left join", function()
			refuses("SELECT a.id FROM a LEFT JOIN b ON a.id = b.a_id", "joins")
		end)

		it("a union", function()
			refuses("SELECT id FROM a UNION SELECT id FROM b", "UNION")
		end)

		it("a group by", function()
			refuses("SELECT id FROM users GROUP BY id", "groups")
		end)

		it("distinct", function()
			refuses("SELECT DISTINCT id FROM users", "DISTINCT")
		end)

		it("an aggregate", function()
			refuses("SELECT COUNT(*) FROM users", "aggregates")
		end)

		it("a window function", function()
			refuses("SELECT id, row_number() OVER (ORDER BY id) FROM users", "window")
		end)

		it("a CTE", function()
			refuses("WITH x AS (SELECT 1) SELECT * FROM x", "not a SELECT")
		end)

		it("a subquery in FROM", function()
			refuses("SELECT id FROM (SELECT id FROM users) t", "subquery")
		end)

		it("an expression in the select list", function()
			refuses("SELECT price * 2 FROM items", "plain columns")
		end)

		it("an aliased column", function()
			refuses("SELECT id AS ident FROM users", "plain columns")
		end)

		it("a cast", function()
			refuses("SELECT id::text FROM users", "plain columns")
		end)

		it("an insert", function()
			refuses("INSERT INTO users (id) VALUES (1)", "not a SELECT")
		end)

		it("an update", function()
			refuses("UPDATE users SET name = 'x'", "not a SELECT")
		end)

		it("multiple statements", function()
			refuses("SELECT id FROM users; SELECT 1", "multiple statements")
		end)

		it("a select with no FROM", function()
			refuses("SELECT 1", "no FROM")
		end)

		it("an empty query", function()
			refuses("", "no query")
		end)
	end)

	describe("resolve_keys", function()
		local columns = {
			{ name = "id", is_primary = true },
			{ name = "name", is_primary = false },
		}

		it("returns the primary key when it is on screen", function()
			local a = provenance.analyze("SELECT id, name FROM users")
			local keys, reason = provenance.resolve_keys(a, columns, { "id", "name" })

			assert.is_nil(reason)
			assert.are.same({ "id" }, keys)
		end)

		it("refuses when the key is not selected", function()
			local a = provenance.analyze("SELECT name FROM users")
			local keys, reason = provenance.resolve_keys(a, columns, { "name" })

			assert.is_nil(keys)
			assert.is_not_nil(reason:find("primary key", 1, true))
		end)

		it("refuses a table with no primary key", function()
			local a = provenance.analyze("SELECT id FROM users")
			local keys, reason = provenance.resolve_keys(a, { { name = "id", is_primary = false } }, { "id" })

			assert.is_nil(keys)
			assert.is_not_nil(reason:find("no primary key", 1, true))
		end)

		it("handles a composite key", function()
			local composite = {
				{ name = "a", is_primary = true },
				{ name = "b", is_primary = true },
			}
			local a = provenance.analyze("SELECT a, b FROM t")
			local keys = provenance.resolve_keys(a, composite, { "a", "b" })

			assert.are.same({ "a", "b" }, keys)
		end)

		it("matches key names case-insensitively", function()
			local a = provenance.analyze("SELECT * FROM users")
			local keys = provenance.resolve_keys(a, columns, { "ID", "NAME" })

			assert.are.same({ "id" }, keys)
		end)

		it("passes the refusal reason through", function()
			local a = provenance.analyze("SELECT a.id FROM a JOIN b ON a.id = b.a_id")
			local keys, reason = provenance.resolve_keys(a, columns, { "id" })

			assert.is_nil(keys)
			assert.is_not_nil(reason:find("joins", 1, true))
		end)
	end)

	describe("string literals cannot smuggle keywords", function()
		---@param query string
		local function accepts(query)
			local a = provenance.analyze(query)
			assert.is_true(a.editable, ("refused %q: %s"):format(query, tostring(a.reason)))
		end

		it("handles a doubled quote", function()
			accepts([[SELECT id FROM users WHERE name = 'O''Brien']])
		end)

		it("handles a doubled quote followed by a keyword in another literal", function()
			accepts([[SELECT id FROM users WHERE name = 'O''Brien' AND note = 'inner join']])
		end)

		it("handles an apostrophe next to a keyword", function()
			accepts([[SELECT id, name FROM users WHERE bio = 'it''s a join of sorts']])
		end)

		it("handles a semicolon inside a literal", function()
			accepts([[SELECT id FROM users WHERE a = 'x;y']])
		end)

		it("handles a line comment mentioning a join", function()
			accepts("SELECT id FROM users -- inner join here\n")
		end)

		it("handles a block comment mentioning a union", function()
			accepts("SELECT id /* union all */ FROM users")
		end)
	end)
end)
