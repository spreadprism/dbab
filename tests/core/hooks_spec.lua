local hooks = require("dbab.core.hooks")
local config = require("dbab.config")

describe("hooks", function()
	local calls

	before_each(function()
		calls = {}
	end)

	---@param name string
	---@return function
	local function record(name)
		return function(ctx)
			table.insert(calls, { name = name, ctx = ctx })
		end
	end

	---@param event string
	---@param conn_name string
	---@return boolean ok, string|nil err
	local function run(event, conn_name)
		local done, ok, err = false, nil, nil

		hooks.run(event, { conn_name = conn_name }, function(o, e)
			ok, err, done = o, e, true
		end)

		vim.wait(1000, function()
			return done
		end)

		return ok, err
	end

	describe("collect", function()
		it("finds nothing when none are configured", function()
			config.setup({ connections = { { name = "a", url = "sqlite:///tmp/a.db" } } })

			assert.are.same({}, hooks.collect("pre_open", "a"))
			assert.is_false(hooks.has("pre_open", "a"))
		end)

		it("accepts a single function", function()
			config.setup({ hooks = { pre_open = record("global") } })

			assert.are.equal(1, #hooks.collect("pre_open", "a"))
		end)

		it("accepts a list", function()
			config.setup({ hooks = { pre_open = { record("one"), record("two") } } })

			assert.are.equal(2, #hooks.collect("pre_open", "a"))
		end)

		it("runs global hooks before the connection's own", function()
			config.setup({
				hooks = { pre_open = record("global") },
				connections = {
					{ name = "a", url = "sqlite:///tmp/a.db", hooks = { pre_open = record("local") } },
				},
			})

			run("pre_open", "a")

			assert.are.equal("global", calls[1].name)
			assert.are.equal("local", calls[2].name)
		end)

		it("does not run another connection's hooks", function()
			config.setup({
				connections = {
					{ name = "a", url = "sqlite:///tmp/a.db", hooks = { pre_open = record("a") } },
					{ name = "b", url = "sqlite:///tmp/b.db", hooks = { pre_open = record("b") } },
				},
			})

			run("pre_open", "b")

			assert.are.equal(1, #calls)
			assert.are.equal("b", calls[1].name)
		end)
	end)

	describe("running", function()
		it("succeeds when there are no hooks", function()
			config.setup({})

			assert.is_true((run("pre_open", "a")))
		end)

		it("passes the context through", function()
			config.setup({ hooks = { pre_open = record("h") } })

			local done
			hooks.run("pre_open", { conn_name = "a", url = "sqlite:///tmp/a.db" }, function()
				done = true
			end)
			vim.wait(500, function()
				return done
			end)

			assert.are.equal("a", calls[1].ctx.conn_name)
			assert.are.equal("sqlite:///tmp/a.db", calls[1].ctx.url)
			assert.are.equal("pre_open", calls[1].ctx.event)
		end)

		it("runs hooks in order", function()
			config.setup({ hooks = { post_open = { record("one"), record("two"), record("three") } } })

			run("post_open", "a")

			assert.are.same(
				{ "one", "two", "three" },
				vim.tbl_map(function(c)
					return c.name
				end, calls)
			)
		end)

		it("waits for an asynchronous hook", function()
			config.setup({
				hooks = {
					pre_open = {
						function(_, done)
							vim.defer_fn(function()
								table.insert(calls, { name = "slow" })
								done(true)
							end, 50)
						end,
						record("after"),
					},
				},
			})

			run("pre_open", "a")

			-- The second hook must not start until the first has finished.
			assert.are.same(
				{ "slow", "after" },
				vim.tbl_map(function(c)
					return c.name
				end, calls)
			)
		end)
	end)

	describe("refusal", function()
		it("lets pre_open veto by calling done(false)", function()
			config.setup({
				hooks = {
					pre_open = function(_, done)
						done(false, "tunnel is down")
					end,
				},
			})

			local ok, err = run("pre_open", "a")

			assert.is_false(ok)
			assert.are.equal("tunnel is down", err)
		end)

		it("lets a synchronous pre_open veto by returning false", function()
			config.setup({ hooks = {
				pre_open = function()
					return false
				end,
			} })

			assert.is_false((run("pre_open", "a")))
		end)

		it("treats an error in pre_open as a refusal", function()
			config.setup({ hooks = {
				pre_open = function()
					error("boom")
				end,
			} })

			local ok, err = run("pre_open", "a")

			assert.is_false(ok)
			assert.is_not_nil(err:find("boom", 1, true))
		end)

		it("does not run later hooks once one refuses", function()
			config.setup({
				hooks = {
					pre_open = {
						function()
							return false
						end,
						record("never"),
					},
				},
			})

			run("pre_open", "a")

			assert.are.same({}, calls)
		end)

		it("does not let a close hook veto", function()
			-- Closing has to stay possible whatever a hook thinks.
			config.setup({
				hooks = {
					pre_close = {
						function()
							error("boom")
						end,
						record("still runs"),
					},
				},
			})

			local ok = run("pre_close", "a")

			assert.is_true(ok)
			assert.are.equal("still runs", calls[1].name)
		end)

		it("does not let post_open veto", function()
			config.setup({ hooks = {
				post_open = function()
					return false
				end,
			} })

			assert.is_true((run("post_open", "a")))
		end)
	end)
end)
