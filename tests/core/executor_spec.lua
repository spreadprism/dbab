local executor = require("dbab.core.executor")

describe("executor", function()
	describe("strip_noise", function()
		it("removes the mysql 8 password warning", function()
			local raw = table.concat({
				"mysql: [Warning] Using a password on the command line interface can be insecure.",
				"id\tname",
				"1\tAlice",
			}, "\n")

			assert.are.equal("id\tname\n1\tAlice", executor.strip_noise(raw))
		end)

		it("removes the mariadb warning", function()
			local raw = "mariadb: [Warning] Using a password on the command line interface can be insecure.\nid\tname"

			assert.are.equal("id\tname", executor.strip_noise(raw))
		end)

		it("removes the mysql 5.x warning", function()
			local raw = "Warning: Using a password on the command line interface can be insecure.\nid\tname"

			assert.are.equal("id\tname", executor.strip_noise(raw))
		end)

		it("leaves ordinary output untouched", function()
			local raw = " id | name\n----+------\n  1 | Alice"

			assert.are.equal(raw, executor.strip_noise(raw))
		end)

		it("keeps error output", function()
			local raw = table.concat({
				"mysql: [Warning] Using a password on the command line interface can be insecure.",
				"ERROR 1146 (42S02) at line 1: Table 'db.nope' doesn't exist",
			}, "\n")

			assert.are.equal("ERROR 1146 (42S02) at line 1: Table 'db.nope' doesn't exist", executor.strip_noise(raw))
		end)

		it("does not strip a value that merely mentions a warning", function()
			local raw = "id\tmessage\n1\tthis mysql: [Warning] came from a column"

			assert.are.equal(raw, executor.strip_noise(raw))
		end)

		it("handles empty and nil input", function()
			assert.are.equal("", executor.strip_noise(""))
			assert.are.equal("", executor.strip_noise(nil))
		end)
	end)
end)
