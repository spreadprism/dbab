local dialect = require("dbab.core.dialect")

describe("dialect", function()
	describe("identifier", function()
		it("double-quotes for postgres and sqlite", function()
			assert.are.equal('"users"', dialect.identifier("users", "postgres"))
			assert.are.equal('"users"', dialect.identifier("users", "sqlite"))
		end)

		it("backtick-quotes for mysql", function()
			assert.are.equal("`users`", dialect.identifier("users", "mysql"))
		end)

		it("quotes unconditionally so reserved words survive", function()
			-- An unquoted `order` is a syntax error, and an unquoted identifier is
			-- case-folded.
			assert.are.equal('"order"', dialect.identifier("order", "postgres"))
			assert.are.equal('"MixedCase"', dialect.identifier("MixedCase", "postgres"))
		end)

		it("escapes the quote character by doubling it", function()
			assert.are.equal('"we""ird"', dialect.identifier('we"ird', "postgres"))
			assert.are.equal("`we``ird`", dialect.identifier("we`ird", "mysql"))
		end)
	end)

	describe("literal", function()
		it("renders nil and vim.NIL as NULL", function()
			assert.are.equal("NULL", dialect.literal(nil, "postgres"))
			assert.are.equal("NULL", dialect.literal(vim.NIL, "postgres"))
		end)

		it("quotes a plain string", function()
			assert.are.equal("'ada'", dialect.literal("ada", "postgres"))
		end)

		it("doubles single quotes", function()
			assert.are.equal("'O''Brien'", dialect.literal("O'Brien", "postgres"))
		end)

		it("also escapes backslashes for mysql", function()
			-- MySQL has backslash escapes active by default.
			assert.are.equal("'a\\\\b'", dialect.literal("a\\b", "mysql"))
		end)

		it("leaves backslashes alone for postgres", function()
			assert.are.equal("'a\\b'", dialect.literal("a\\b", "postgres"))
		end)

		it("keeps an empty string distinct from NULL", function()
			assert.are.equal("''", dialect.literal("", "postgres"))
		end)

		it("does not let a quote break out of the literal", function()
			local out = dialect.literal("x'; DROP TABLE users; --", "postgres")

			assert.are.equal("'x''; DROP TABLE users; --'", out)
		end)
	end)

	describe("update", function()
		it("builds a single-column update", function()
			local sql = dialect.update({
				table_name = "users",
				sets = { { column = "email", value = "ada@example.com" } },
				wheres = { { column = "id", value = "42" } },
			}, "postgres")

			assert.are.equal([[UPDATE "users" SET "email" = 'ada@example.com' WHERE "id" = '42';]], sql)
		end)

		it("puts several columns in one statement", function()
			local sql = dialect.update({
				table_name = "users",
				sets = { { column = "a", value = "1" }, { column = "b", value = vim.NIL } },
				wheres = { { column = "id", value = "7" } },
			}, "mysql")

			assert.are.equal("UPDATE `users` SET `a` = '1', `b` = NULL WHERE `id` = '7';", sql)
		end)

		it("ANDs a composite key", function()
			local sql = dialect.update({
				table_name = "t",
				sets = { { column = "v", value = "x" } },
				wheres = { { column = "a", value = "1" }, { column = "b", value = "2" } },
			}, "postgres")

			assert.is_not_nil(sql:find([[WHERE "a" = '1' AND "b" = '2']], 1, true))
		end)

		it("qualifies with a schema when given one", function()
			local sql = dialect.update({
				table_name = "users",
				schema = "public",
				sets = { { column = "v", value = "x" } },
				wheres = { { column = "id", value = "1" } },
			}, "postgres")

			assert.is_not_nil(sql:find([[UPDATE "public"."users"]], 1, true))
		end)
	end)

	describe("guard", function()
		it("wraps postgres in a DO block that checks ROW_COUNT", function()
			local out = dialect.guard({ "UPDATE t SET a = 1;" }, "postgres")

			assert.is_not_nil(out:find("DO $dbab$", 1, true))
			assert.is_not_nil(out:find("GET DIAGNOSTICS affected = ROW_COUNT;", 1, true))
			assert.is_not_nil(out:find("RAISE EXCEPTION", 1, true))
		end)

		it("wraps mysql in a transaction with a runtime abort", function()
			local out = dialect.guard({ "UPDATE t SET a = 1;" }, "mysql")

			assert.is_not_nil(out:find("START TRANSACTION;", 1, true))
			assert.is_not_nil(out:find("ROW_COUNT() = 1", 1, true))
			assert.is_not_nil(out:find("COMMIT;", 1, true))
		end)

		it("bails sqlite on the first error", function()
			-- Without `.bail on` sqlite3 reports the error and commits anyway.
			local out = dialect.guard({ "UPDATE t SET a = 1;" }, "sqlite")

			assert.are.equal(".bail on", vim.split(out, "\n")[1])
			assert.is_not_nil(out:find("changes() <> 1", 1, true))
		end)

		it("returns nothing for no statements", function()
			assert.are.equal("", dialect.guard({}, "postgres"))
		end)

		it("guards every statement, not just the first", function()
			local out = dialect.guard({ "UPDATE t SET a = 1;", "UPDATE t SET b = 2;" }, "postgres")
			local _, count = out:gsub("GET DIAGNOSTICS", "")

			assert.are.equal(2, count)
		end)
	end)
end)
