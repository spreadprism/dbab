local schema = require("dbab.core.schema")

-- MySQL writes its password warning to stderr, which `systemlist` merges into
-- stdout. The schema parsers sniff line 1 for a tab to detect MySQL's
-- tab-separated format, so a leading warning line used to make all of them fall
-- through to the PostgreSQL branch and return nothing at all.
describe("schema parsing (mysql)", function()
	local WARNING = "mysql: [Warning] Using a password on the command line interface can be insecure."

	describe("parse_schemas", function()
		it("parses tab separated output", function()
			local raw = "SCHEMA_NAME\ttable_count\nmydb\t38"

			local schemas = schema.parse_schemas(raw)

			assert.are.equal(1, #schemas)
			assert.are.equal("mydb", schemas[1].name)
			assert.are.equal(38, schemas[1].table_count)
		end)

		it("returns nothing when the warning is left in place", function()
			-- Documents the failure mode the executor now prevents.
			local raw = WARNING .. "\nSCHEMA_NAME\ttable_count\nmydb\t38"

			assert.are.equal(0, #schema.parse_schemas(raw))
		end)
	end)

	describe("parse_tables", function()
		it("parses tab separated output", function()
			local raw = "TABLE_NAME\tTABLE_TYPE\nusers\tBASE TABLE\nv_active\tVIEW"

			local tables = schema.parse_tables(raw, "mysql")

			assert.are.equal(2, #tables)
			assert.are.equal("users", tables[1].name)
			assert.are.equal("v_active", tables[2].name)
		end)
	end)

	describe("parse_columns", function()
		it("parses tab separated output", function()
			local raw = table.concat({
				"COLUMN_NAME\tDATA_TYPE\tIS_NULLABLE\tis_primary",
				"id\tint\tNO\tYES",
				"email\tvarchar\tYES\tNO",
			}, "\n")

			local columns = schema.parse_columns(raw, "mysql")

			assert.are.equal(2, #columns)

			assert.are.equal("id", columns[1].name)
			assert.are.equal("int", columns[1].data_type)
			assert.is_false(columns[1].is_nullable)
			assert.is_true(columns[1].is_primary)

			assert.are.equal("email", columns[2].name)
			assert.is_true(columns[2].is_nullable)
			assert.is_false(columns[2].is_primary)
		end)
	end)
end)
