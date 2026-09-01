local editable = require("dbab.ui.editable")
local parser = require("dbab.utils.parser")

describe("editable", function()
	describe("parse_cell", function()
		it("reads the exact text NULL as a null", function()
			assert.are.equal(vim.NIL, editable.parse_cell("NULL"))
			assert.are.equal(vim.NIL, editable.parse_cell("  NULL  "))
		end)

		it("does not treat other casings as null", function()
			assert.are.equal("null", editable.parse_cell("null"))
		end)

		it("strips the padding", function()
			assert.are.equal("ada", editable.parse_cell("ada   "))
		end)

		it("keeps an empty cell as an empty string", function()
			assert.are.equal("", editable.parse_cell("   "))
		end)
	end)

	describe("anchors and dirty cells", function()
		local buf, state

		--- Render a grid into a scratch buffer the same way the result pane does.
		---@param result Dbab.QueryResult
		local function render(result)
			buf = vim.api.nvim_create_buf(false, true)

			local widths = parser.calculate_column_widths(result)
			local lines, spans = {}, {}

			local header, header_spans = parser.render_row(result.columns, widths)
			table.insert(lines, header)
			table.insert(spans, header_spans)

			for _, row in ipairs(result.rows) do
				local line, row_spans = parser.render_row(row, widths)
				table.insert(lines, line)
				table.insert(spans, row_spans)
			end

			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			state = {
				url = "sqlite:///tmp/x.db",
				db_type = "sqlite",
				query = "SELECT id, name FROM users",
				editable = true,
				table_name = "users",
				keys = { "id" },
				result = result,
			}

			editable.attach(buf, state, spans, 1)

			return buf
		end

		local function fixture()
			return render({
				columns = { "id", "name" },
				rows = { { "1", "ada" }, { "2", "grace" } },
				row_count = 2,
				raw = "",
			})
		end

		after_each(function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				editable.detach(buf)
				vim.api.nvim_buf_delete(buf, { force = true })
			end
			buf = nil
		end)

		---@param row number 0-indexed buffer line
		---@param needle string
		---@param replacement string
		local function retype(row, needle, replacement)
			local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
			local from = line:find(needle, 1, true) - 1
			vim.api.nvim_buf_set_text(buf, row, from, row, from + #needle, { replacement })
		end

		it("reports nothing when nothing was touched", function()
			fixture()

			assert.are.same({}, editable.dirty_cells(buf))
		end)

		it("notices a changed cell", function()
			fixture()
			retype(1, "ada", "ADA")

			local dirty = editable.dirty_cells(buf)

			assert.are.equal(1, #dirty)
			assert.are.equal(1, dirty[1].row)
			assert.are.equal(2, dirty[1].column)
			assert.are.equal("ADA", dirty[1].value)
		end)

		it("follows the cell when text before it grows", function()
			fixture()
			-- Widening the first cell shifts the second one right; the anchor moves
			-- with it rather than being re-derived from the text.
			retype(1, "1", "1000")
			retype(1, "ada", "ADA")

			local dirty = editable.dirty_cells(buf)
			local by_column = {}
			for _, cell in ipairs(dirty) do
				by_column[cell.column] = cell.value
			end

			assert.are.equal("1000", by_column[1])
			assert.are.equal("ADA", by_column[2])
		end)

		it("reads a typed NULL as a null", function()
			fixture()
			retype(1, "ada", "NULL")

			local dirty = editable.dirty_cells(buf)

			assert.are.equal(vim.NIL, dirty[1].value)
		end)

		it("survives a value containing the separator", function()
			render({
				columns = { "id", "name" },
				rows = { { "1", "a|b" } },
				row_count = 1,
				raw = "",
			})
			retype(1, "a|b", "c|d")

			local dirty = editable.dirty_cells(buf)

			assert.are.equal(1, #dirty)
			assert.are.equal("c|d", dirty[1].value)
		end)
	end)

	describe("statements", function()
		local buf

		local function build(result, overrides)
			buf = vim.api.nvim_create_buf(false, true)

			local widths = parser.calculate_column_widths(result)
			local lines, spans = {}, {}
			local header, header_spans = parser.render_row(result.columns, widths)
			table.insert(lines, header)
			table.insert(spans, header_spans)
			for _, row in ipairs(result.rows) do
				local line, row_spans = parser.render_row(row, widths)
				table.insert(lines, line)
				table.insert(spans, row_spans)
			end
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

			local state = vim.tbl_extend("force", {
				url = "x",
				db_type = "postgres",
				query = "SELECT id, name FROM users",
				editable = true,
				table_name = "users",
				keys = { "id" },
				result = result,
			}, overrides or {})

			editable.attach(buf, state, spans, 1)

			return buf
		end

		after_each(function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				editable.detach(buf)
				vim.api.nvim_buf_delete(buf, { force = true })
			end
			buf = nil
		end)

		local function two_rows()
			return build({
				columns = { "id", "name", "note" },
				rows = { { "1", "ada", "x" }, { "2", "grace", "y" } },
				row_count = 2,
				raw = "",
			})
		end

		local function retype(row, needle, replacement)
			local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
			local from = line:find(needle, 1, true) - 1
			vim.api.nvim_buf_set_text(buf, row, from, row, from + #needle, { replacement })
		end

		it("returns nothing when the buffer is untouched", function()
			two_rows()
			local statements, err = editable.statements(buf)

			assert.is_nil(err)
			assert.are.same({}, statements)
		end)

		it("writes only the columns that changed", function()
			two_rows()
			retype(1, "ada", "ADA")

			local statements = editable.statements(buf)

			assert.are.equal(1, #statements)
			assert.are.equal([[UPDATE "users" SET "name" = 'ADA' WHERE "id" = '1';]], statements[1])
		end)

		it("groups several edits to one row into one statement", function()
			two_rows()
			retype(1, "ada", "ADA")
			retype(1, "x", "X")

			local statements = editable.statements(buf)

			assert.are.equal(1, #statements)
			assert.is_not_nil(statements[1]:find([[SET "name" = 'ADA', "note" = 'X']], 1, true))
		end)

		it("emits one statement per edited row", function()
			two_rows()
			retype(1, "ada", "ADA")
			retype(2, "grace", "GRACE")

			assert.are.equal(2, #editable.statements(buf))
		end)

		it("keys the WHERE off the original value, not the edited one", function()
			two_rows()
			-- Edit the key column itself: the row to find is the one identified by
			-- its OLD value.
			retype(1, "1", "99")

			local statements = editable.statements(buf)

			assert.is_not_nil(statements[1]:find([[SET "id" = '99']], 1, true))
			assert.is_not_nil(statements[1]:find([[WHERE "id" = '1']], 1, true))
		end)

		it("writes a typed NULL unquoted", function()
			two_rows()
			retype(1, "x", "NULL")

			local statements = editable.statements(buf)

			assert.is_not_nil(statements[1]:find([[SET "note" = NULL]], 1, true))
		end)

		it("refuses when a line was deleted", function()
			two_rows()
			vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})

			local statements, err = editable.statements(buf)

			assert.are.same({}, statements)
			assert.is_not_nil(err:find("added or removed", 1, true))
		end)

		it("refuses when a whole line was replaced", function()
			two_rows()
			vim.api.nvim_buf_set_lines(buf, 1, 2, false, { " 9 | zz | q " })

			local statements, err = editable.statements(buf)

			assert.are.same({}, statements)
			assert.is_not_nil(err:find("replaced rather than edited", 1, true))
		end)

		it("refuses a result that is not editable", function()
			build({ columns = { "n" }, rows = { { "1" } }, row_count = 1, raw = "" }, {
				editable = false,
				reason = "query aggregates rows",
			})

			local statements, err = editable.statements(buf)

			assert.are.same({}, statements)
			assert.are.equal("query aggregates rows", err)
		end)

		it("escapes a quote in an edited value", function()
			two_rows()
			retype(1, "ada", "O'Brien")

			local statements = editable.statements(buf)

			assert.is_not_nil(statements[1]:find([['O''Brien']], 1, true))
		end)
	end)
end)
