test_helpers = Path.expand("../test_helpers", __DIR__)

Code.require_file("reach/test/program_facts/project.ex", test_helpers)
Code.require_file("reach/test/program_facts/normalize.ex", test_helpers)
Code.require_file("reach/test/program_facts/api.ex", test_helpers)
Code.require_file("reach/test/program_facts/assertions.ex", test_helpers)
Code.require_file("reach/test/program_facts/cli.ex", test_helpers)

unless Code.ensure_loaded?(Boxart) do
  ExUnit.configure(exclude: [:boxart])
end

ExUnit.start()
