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

		confirm.show({ lines = lines, prompt = "Apply 1 statement?", lang = "sql" }, function(ok)
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
end)
