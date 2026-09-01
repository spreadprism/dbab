local highlights = require("dbab.ui.highlights")
local config = require("dbab.config")

describe("highlights", function()
	before_each(function()
		config.setup({})
		pcall(vim.api.nvim_set_hl, 0, "DbabSeparator", {})
		vim.cmd("hi clear DbabSeparator")
	end)

	describe("DbabSeparator", function()
		it("takes Comment's colour without its attributes", function()
			-- Linking would inherit the italics most colourschemes give comments,
			-- which slants the one glyph whose job is to be a straight line.
			vim.cmd("hi Comment guifg=#7f849c gui=italic")
			highlights.setup()

			local hl = vim.api.nvim_get_hl(0, { name = "DbabSeparator", link = false })

			assert.are.equal(tonumber("7f849c", 16), hl.fg)
			assert.is_not_true(hl.italic)
		end)

		it("stays upright when Comment is bold and underlined too", function()
			vim.cmd("hi Comment guifg=#7f849c gui=italic,bold,underline")
			highlights.setup()

			local hl = vim.api.nvim_get_hl(0, { name = "DbabSeparator", link = false })

			assert.is_not_true(hl.italic)
			assert.is_not_true(hl.bold)
			assert.is_not_true(hl.underline)
		end)

		it("respects a group the user defined beforehand", function()
			vim.cmd("hi DbabSeparator guifg=#ff0000 gui=bold")
			highlights.setup()

			local hl = vim.api.nvim_get_hl(0, { name = "DbabSeparator", link = false })

			assert.are.equal(tonumber("ff0000", 16), hl.fg)
			assert.is_true(hl.bold)
		end)

		it("respects a setup() override", function()
			config.setup({ highlights = { DbabSeparator = { fg = "#00ff00" } } })
			highlights.setup()

			local hl = vim.api.nvim_get_hl(0, { name = "DbabSeparator", link = false })

			assert.are.equal(tonumber("00ff00", 16), hl.fg)
		end)
	end)
end)
