local parser = require("dbab.utils.parser")

-- The offset walk is the substrate for everything downstream: per-cell
-- highlighting, "which column is the cursor in", and any future editable-cell
-- anchors. If `render_row` and the spans it reports ever disagree about padding
-- or the separator, highlights land a character off.
describe("grid geometry", function()
	describe("display", function()
		it("renders nil and vim.NIL as NULL", function()
			assert.are.equal("NULL", parser.display(nil))
			assert.are.equal("NULL", parser.display(vim.NIL))
		end)

		it("keeps an empty string distinct from NULL", function()
			assert.are.equal("", parser.display(""))
		end)

		it("passes other values through", function()
			assert.are.equal("0", parser.display("0"))
			assert.are.equal("false", parser.display("false"))
			assert.are.equal("42", parser.display(42))
		end)
	end)

	describe("sanitize", function()
		it("replaces tabs, newlines and carriage returns", function()
			assert.are.equal("a b", parser.sanitize("a\tb"))
			assert.are.equal("a b", parser.sanitize("a\nb"))
			assert.are.equal("a b", parser.sanitize("a\r\nb"))
		end)

		it("replaces control characters", function()
			assert.are.equal("a b", parser.sanitize("a\1b"))
		end)

		it("leaves ordinary text alone", function()
			assert.are.equal("ada@example.com", parser.sanitize("ada@example.com"))
		end)
	end)

	describe("calculate_column_widths", function()
		it("takes the widest of the header and every value", function()
			local widths = parser.calculate_column_widths({
				columns = { "id", "email" },
				rows = { { "1", "ada@example.com" }, { "22", "x" } },
			})

			assert.are.same({ 2, 15 }, widths)
		end)

		it("measures NULL as it will be printed", function()
			local widths = parser.calculate_column_widths({
				columns = { "n" },
				rows = { { vim.NIL } },
			})

			assert.are.equal(4, widths[1])
		end)

		it("measures display width, not byte length", function()
			-- "José" is 5 bytes but 4 columns; pad by bytes and the grid skews.
			local widths = parser.calculate_column_widths({
				columns = { "name" },
				rows = { { "José" } },
			})

			assert.are.equal(4, widths[1])
		end)

		it("measures wide characters as two columns", function()
			local widths = parser.calculate_column_widths({
				columns = { "c" },
				rows = { { "数" } },
			})

			assert.are.equal(2, widths[1])
		end)
	end)

	describe("render_row", function()
		it("pads each cell and joins with a single separator", function()
			local line = parser.render_row({ "1", "ada" }, { 2, 5 })

			assert.are.equal(" 1  | ada   ", line)
		end)

		it("puts nothing but the separator between two cells", function()
			local line = parser.render_row({ "a", "b" }, { 1, 1 })

			assert.are.equal(" a | b ", line)
		end)

		it("reports byte spans that bracket the value without its padding", function()
			local line, spans = parser.render_row({ "1", "ada" }, { 2, 5 })

			assert.are.equal("1", line:sub(spans[1].from + 1, spans[1].to))
			assert.are.equal("ada", line:sub(spans[2].from + 1, spans[2].to))
		end)

		it("keeps spans correct for non-ASCII data", function()
			local line, spans = parser.render_row({ "José", "x" }, { 4, 1 })

			-- Byte offsets, not columns: "José" is 5 bytes wide.
			assert.are.equal("José", line:sub(spans[1].from + 1, spans[1].to))
			assert.are.equal("x", line:sub(spans[2].from + 1, spans[2].to))
		end)

		it("keeps columns aligned when a value is non-ASCII", function()
			local widths = { 4, 3 }
			local a = parser.render_row({ "José", "abc" }, widths)
			local b = parser.render_row({ "ab", "abc" }, widths)

			assert.are.equal(vim.fn.strdisplaywidth(a), vim.fn.strdisplaywidth(b))
		end)

		it("renders a null cell as NULL", function()
			local line = parser.render_row({ vim.NIL, "x" }, { 4, 1 })

			assert.are.equal(" NULL | x ", line)
		end)

		it("renders an empty string as blank, not NULL", function()
			local line = parser.render_row({ "", "x" }, { 4, 1 })

			assert.are.equal("      | x ", line)
		end)

		it("does not let a pipe in the data break the spans", function()
			-- The rendered text is an output, never an input: splitting this line
			-- on "|" would mis-split exactly the rows that matter.
			local line, spans = parser.render_row({ "a|b", "c" }, { 3, 1 })

			assert.are.equal("a|b", line:sub(spans[1].from + 1, spans[1].to))
			assert.are.equal("c", line:sub(spans[2].from + 1, spans[2].to))
		end)

		it("flattens a value containing a newline", function()
			local line = parser.render_row({ "a\nb" }, { 3 })

			assert.is_nil(line:match("\n"))
		end)
	end)

	describe("column_at", function()
		it("finds the column under a byte offset", function()
			local widths = { 2, 5 }

			assert.are.equal(1, parser.column_at(widths, 1))
			assert.are.equal(2, parser.column_at(widths, 6))
		end)

		it("counts the trailing pad as part of its cell", function()
			local widths = { 2, 5 }

			assert.are.equal(1, parser.column_at(widths, 2))
		end)

		it("returns nil past the end of the row", function()
			assert.is_nil(parser.column_at({ 2, 5 }, 999))
		end)

		it("agrees with the spans render_row reported", function()
			local widths = { 2, 5, 3 }
			local _, spans = parser.render_row({ "1", "ada", "xy" }, widths)

			for index, span in ipairs(spans) do
				assert.are.equal(index, parser.column_at(widths, span.from))
			end
		end)
	end)

	describe("to_value", function()
		it("turns the sentinel into vim.NIL", function()
			assert.are.equal(vim.NIL, parser.to_value(parser.NULL_SENTINEL))
		end)

		it("leaves an empty string alone", function()
			assert.are.equal("", parser.to_value(""))
		end)

		it("treats mysql's bare NULL as null", function()
			assert.are.equal(vim.NIL, parser.to_value("NULL", "mysql"))
		end)

		it("keeps the string 'NULL' as a value for dialects with a sentinel", function()
			assert.are.equal("NULL", parser.to_value("NULL", "postgres"))
		end)
	end)
end)
