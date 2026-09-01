local sticky = require("dbab.ui.sticky")
local config = require("dbab.config")

describe("sticky", function()
	local buf, win, wb

	local function make_grid(rows)
		buf = vim.api.nvim_create_buf(false, true)
		local lines = { " id | name " }
		for i = 1, rows do
			table.insert(lines, string.format(" %-2d | row%d ", i, i))
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		vim.cmd("new")
		win = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(win, buf)
		vim.api.nvim_win_set_height(win, 5)
		vim.wo[win].wrap = false
	end

	before_each(function()
		config.setup({ result = { sticky_header = true } })
		wb = { id = 99, sticky = {} }
	end)

	after_each(function()
		sticky.cleanup(wb)
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		win = nil
		buf = nil
	end)

	describe("set_header", function()
		it("stores the header line", function()
			sticky.set_header(wb, " id | name ")
			assert.are.equal(" id | name ", wb.sticky.header)
		end)

		it("hides the float when set to nil", function()
			make_grid(50)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 40, 0 })
			vim.cmd("normal! zt")
			sticky.follow(wb, win)

			sticky.set_header(wb, nil)

			assert.is_nil(wb.sticky.header)
			assert.is_nil(wb.sticky.win)
		end)
	end)

	describe("follow", function()
		it("does nothing without a header", function()
			make_grid(50)
			sticky.follow(wb, win)
			assert.is_nil(wb.sticky.win)
		end)

		it("stays hidden while the header line is visible", function()
			make_grid(50)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 1, 0 })
			vim.cmd("normal! zt")

			sticky.follow(wb, win)

			assert.is_nil(wb.sticky.win)
		end)

		it("opens a float once scrolled past the header", function()
			make_grid(50)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 30, 0 })
			vim.cmd("normal! zt")

			sticky.follow(wb, win)

			assert.is_not_nil(wb.sticky.win)
			assert.is_true(vim.api.nvim_win_is_valid(wb.sticky.win))

			local lines = vim.api.nvim_buf_get_lines(wb.sticky.buf, 0, -1, false)
			assert.are.equal(" id | name ", lines[1])

			local cfg = vim.api.nvim_win_get_config(wb.sticky.win)
			assert.are.equal("win", cfg.relative)
			assert.are.equal(1, cfg.height)
			assert.is_false(cfg.focusable)
		end)

		it("reuses the same window instead of reopening it", function()
			make_grid(50)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 30, 0 })
			vim.cmd("normal! zt")

			sticky.follow(wb, win)
			local first = wb.sticky.win
			sticky.follow(wb, win)

			assert.are.equal(first, wb.sticky.win)
		end)

		it("hides again when scrolled back to the top", function()
			make_grid(50)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 30, 0 })
			vim.cmd("normal! zt")
			sticky.follow(wb, win)
			assert.is_not_nil(wb.sticky.win)

			vim.api.nvim_win_set_cursor(win, { 1, 0 })
			vim.cmd("normal! zt")
			sticky.follow(wb, win)

			assert.is_nil(wb.sticky.win)
		end)

		it("stays hidden when disabled in config", function()
			config.setup({ result = { sticky_header = false } })
			make_grid(50)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 30, 0 })
			vim.cmd("normal! zt")

			sticky.follow(wb, win)

			assert.is_nil(wb.sticky.win)
		end)

		it("ignores an invalid window", function()
			sticky.set_header(wb, " id | name ")
			sticky.follow(wb, nil)
			assert.is_nil(wb.sticky.win)
		end)
	end)

	describe("skip_header", function()
		it("moves the cursor off the header line", function()
			make_grid(5)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 1, 0 })

			sticky.skip_header(wb, win)

			assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
		end)

		it("clamps the column to the line it lands on", function()
			make_grid(1)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " a_very_long_header ", " x " })
			sticky.set_header(wb, " a_very_long_header ")
			vim.api.nvim_win_set_cursor(win, { 1, 18 })

			sticky.skip_header(wb, win)

			local pos = vim.api.nvim_win_get_cursor(win)
			assert.are.equal(2, pos[1])
			assert.is_true(pos[2] <= 2)
		end)

		it("leaves the cursor alone below the header", function()
			make_grid(5)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 4, 0 })

			sticky.skip_header(wb, win)

			assert.are.equal(4, vim.api.nvim_win_get_cursor(win)[1])
		end)

		it("keeps the cursor when the header has no rows under it", function()
			buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " id | name " })
			vim.cmd("new")
			win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, buf)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 1, 0 })

			sticky.skip_header(wb, win)

			assert.are.equal(1, vim.api.nvim_win_get_cursor(win)[1])
		end)
	end)

	describe("cleanup", function()
		it("closes the float and clears state", function()
			make_grid(50)
			sticky.set_header(wb, " id | name ")
			vim.api.nvim_win_set_cursor(win, { 30, 0 })
			vim.cmd("normal! zt")
			sticky.follow(wb, win)

			local float = wb.sticky.win
			sticky.cleanup(wb)

			assert.is_false(vim.api.nvim_win_is_valid(float))
			assert.is_nil(wb.sticky.win)
			assert.is_nil(wb.sticky.buf)
			assert.is_nil(wb.sticky.header)
		end)
	end)
end)
