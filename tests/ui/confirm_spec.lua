local confirm = require("dbab.ui.confirm")

-- The prompt answers to a single keypress, in the style of oil.nvim's change
-- confirmation: buffer-local `nowait` mappings on a focused float, not a typed
-- response and not `getchar()`.
describe("confirm float", function()
	local answered

	---@param lines string[]
	---@return number win, number buf
	local function open(lines)
		answered = nil

		local prompt = ("Apply %d statement%s?"):format(#lines, #lines == 1 and "" or "s")

		confirm.show({ lines = lines, prompt = prompt, lang = "sql", count = #lines }, function(ok)
			answered = ok
		end)

		-- `show` is schedule-wrapped so the float is reliably entered.
		vim.wait(500, function()
			return vim.api.nvim_win_get_config(0).relative ~= ""
		end)

		local win = vim.api.nvim_get_current_win()

		return win, vim.api.nvim_win_get_buf(win)
	end

	---@param key string
	local function press(key)
		vim.api.nvim_feedkeys(key, "x", false)
		vim.wait(500, function()
			return answered ~= nil
		end)
	end

	after_each(function()
		local win = vim.api.nvim_get_current_win()
		if vim.api.nvim_win_get_config(win).relative ~= "" then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end)

	it("opens a centred float above other windows", function()
		local win = open({ "SELECT 1;" })
		local cfg = vim.api.nvim_win_get_config(win)

		assert.are.equal("editor", cfg.relative)
		assert.are.equal(152, cfg.zindex)

		press("n")
	end)

	it("shows the statements", function()
		local _, buf = open({ "UPDATE t SET a = 1;", "UPDATE t SET b = 2;" })

		assert.are.same({ "UPDATE t SET a = 1;", "UPDATE t SET b = 2;" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

		press("n")
	end)

	it("is not editable", function()
		local _, buf = open({ "SELECT 1;" })

		assert.is_false(vim.bo[buf].modifiable)
		assert.are.equal("wipe", vim.bo[buf].bufhidden)

		press("n")
	end)

	it("highlights the body as SQL when a parser is available", function()
		local _, buf = open({ "SELECT 1;" })

		if pcall(vim.treesitter.language.add, "sql") then
			assert.is_true(pcall(vim.treesitter.get_parser, buf, "sql"))
		end

		press("n")
	end)

	it("binds single-key answers with nowait", function()
		local _, buf = open({ "SELECT 1;" })

		local keys = {}
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
			keys[map.lhs] = map.nowait
		end

		for _, key in ipairs({ "y", "Y", "n", "N", "q" }) do
			assert.is_not_nil(keys[key], key .. " is not bound")
			assert.are.equal(1, keys[key], key .. " should be nowait")
		end

		press("n")
	end)

	it("confirms on y without needing Enter", function()
		open({ "SELECT 1;" })

		press("y")

		assert.is_true(answered)
	end)

	it("cancels on n", function()
		open({ "SELECT 1;" })

		press("n")

		assert.is_false(answered)
	end)

	it("cancels on <Esc>", function()
		open({ "SELECT 1;" })

		press(vim.api.nvim_replace_termcodes("<Esc>", true, false, true))

		assert.is_false(answered)
	end)

	it("closes the window once answered", function()
		local win = open({ "SELECT 1;" })

		press("y")

		assert.is_false(vim.api.nvim_win_is_valid(win))
	end)

	it("treats leaving the window as a refusal", function()
		open({ "SELECT 1;" })

		vim.cmd("wincmd p")
		vim.wait(500, function()
			return answered ~= nil
		end)

		assert.is_false(answered)
	end)

	it("answers only once", function()
		open({ "SELECT 1;" })

		press("y")
		local first = answered

		answered = nil
		press("y")

		assert.is_true(first)
		assert.is_nil(answered)
	end)

	describe("many statements", function()
		---@param n number
		---@return string[]
		local function statements(n)
			local lines = {}
			for i = 1, n do
				lines[i] = ("UPDATE t SET a = %d WHERE id = %d;"):format(i, i)
			end
			return lines
		end

		---@param cfg vim.api.keyset.win_config
		---@param key string
		---@return string
		local function border_text(cfg, key)
			local value = cfg[key]
			if type(value) ~= "table" then
				return tostring(value)
			end

			local parts = {}
			for _, chunk in ipairs(value) do
				table.insert(parts, chunk[1])
			end

			return table.concat(parts)
		end

		it("keeps every statement in the buffer", function()
			local _, buf = open(statements(7))

			assert.are.equal(7, vim.api.nvim_buf_line_count(buf))

			press("n")
		end)

		it("shows at most five at a time", function()
			local win = open(statements(7))

			assert.are.equal(5, vim.api.nvim_win_get_config(win).height)

			press("n")
		end)

		it("fits the window to the content when it is short", function()
			local win = open(statements(3))

			assert.are.equal(3, vim.api.nvim_win_get_config(win).height)

			press("n")
		end)

		it("names the total in the title so it cannot be missed", function()
			local win = open(statements(7))

			assert.is_not_nil(border_text(vim.api.nvim_win_get_config(win), "title"):find("7", 1, true))

			press("n")
		end)

		it("says so in the footer when statements are off screen", function()
			local win = open(statements(7))
			local footer = border_text(vim.api.nvim_win_get_config(win), "footer")

			assert.is_not_nil(footer:find("5 of 7", 1, true))
			assert.is_not_nil(footer:find("scroll", 1, true))

			press("n")
		end)

		it("does not claim anything is hidden when it all fits", function()
			local win = open(statements(4))
			local footer = border_text(vim.api.nvim_win_get_config(win), "footer")

			assert.is_nil(footer:find("scroll", 1, true))

			press("n")
		end)

		it("scrolls to the statements below the fold", function()
			local win = open(statements(7))

			assert.are.equal(1, vim.fn.line("w0", win))
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
			assert.is_true(vim.fn.line("w0", win) > 1)

			press("n")
		end)

		it("still answers with one key while scrolled", function()
			open(statements(7))

			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-d>", true, false, true), "x", false)
			press("y")

			assert.is_true(answered)
		end)

		it("refuses an empty body rather than opening a blank window", function()
			local called
			confirm.show({ lines = {}, prompt = "Apply?" }, function(ok)
				called = ok
			end)
			vim.wait(200, function()
				return called ~= nil
			end)

			assert.is_false(called)
		end)
	end)
end)
