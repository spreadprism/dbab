local selection = require("dbab.utils.selection")

describe("selection", function()
	local lines = {
		"SELECT 1;",
		"SELECT * FROM users",
		"WHERE id = 1;",
	}

	describe("normalize", function()
		it("keeps ordered ranges", function()
			local sr, sc, er, ec = selection.normalize(1, 1, 2, 5)
			assert.are.equal(0, sr)
			assert.are.equal(0, sc)
			assert.are.equal(1, er)
			assert.are.equal(5, ec)
		end)

		it("swaps reversed ranges", function()
			local sr, sc, er, ec = selection.normalize(3, 4, 1, 2)
			assert.are.equal(0, sr)
			assert.are.equal(1, sc)
			assert.are.equal(2, er)
			assert.are.equal(4, ec)
		end)

		it("swaps reversed columns on the same row", function()
			local sr, sc, er, ec = selection.normalize(2, 9, 2, 3)
			assert.are.equal(1, sr)
			assert.are.equal(2, sc)
			assert.are.equal(1, er)
			assert.are.equal(9, ec)
		end)
	end)

	describe("extract", function()
		it("extracts a charwise selection on a single line", function()
			assert.are.equal("SELECT", selection.extract(lines, 1, 1, 1, 6, "v"))
		end)

		it("extracts a charwise selection across lines", function()
			local got = selection.extract(lines, 2, 1, 3, 13, "v")
			assert.are.equal("SELECT * FROM users\nWHERE id = 1;", got)
		end)

		it("extracts a linewise selection in full", function()
			local got = selection.extract(lines, 2, 5, 3, 2, "V")
			assert.are.equal("SELECT * FROM users\nWHERE id = 1;", got)
		end)

		it("extracts a blockwise selection", function()
			local got = selection.extract(lines, 1, 1, 3, 6, "\22")
			assert.are.equal("SELECT\nSELECT\nWHERE ", got)
		end)

		it("handles a reversed selection", function()
			assert.are.equal("SELECT", selection.extract(lines, 1, 6, 1, 1, "v"))
		end)

		it("returns empty string when the range is out of bounds", function()
			assert.are.equal("", selection.extract({}, 1, 1, 2, 3, "v"))
		end)
	end)
end)
