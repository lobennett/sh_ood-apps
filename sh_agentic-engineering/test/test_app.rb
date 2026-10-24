#!/usr/bin/env ruby
# Render the real app templates and exercise the rendered lifecycle against
# controlled Slurm, module, harness, and Herdr doubles.
require "English"
require "erb"
require "etc"
require "fileutils"
require "open3"
require "ostruct"
require "pathname"
require "shellwords"
require "tmpdir"
require "yaml"
require "minitest/autorun"

class AgenticEngineeringTest < Minitest::Test
  APP = Pathname.new(File.expand_path("..", __dir__))
  DEFAULTS = { ae_session: "agentic-engineering", ae_harness: "claude", ae_home: "$HOME/firstmate",
               bc_queue: "russpold", sh_cpus: "8", sh_mem: "32", bc_num_hours: "8", sh_modules: "",
               bc_email_on_started: "0" }.freeze
  NODE = "sh03-01n01".freeze
  JOB = "12345".freeze
  USER = Etc.getpwuid(Process.uid).name
  MARKER = "sh_agentic-engineering/agentic-engineering".freeze

  FAKE_HERDR = <<~'BASH'
    #!/usr/bin/env bash
    set -u
    if [[ ${1:-} == --version ]]; then echo 'herdr 0.8.2'; exit 0; fi
    : "${HERDR_SESSION:?missing HERDR_SESSION}" "${HERDR_SOCKET_PATH:?missing HERDR_SOCKET_PATH}"
    printf '%s|%s|%s\n' "$HERDR_SESSION" "$HERDR_SOCKET_PATH" "$*" >> "${HERDR_LOG:?}"
    case "${1:-} ${2:-}" in
      'server stop')
        [[ -f ${FAKE_SERVER_PID:?} ]] && kill "$(< "$FAKE_SERVER_PID")" 2>/dev/null
        exit 0 ;;
      'server ')
        [[ ${FAKE_SERVER_EXIT:-0} == 0 ]] || { echo 'fake server refused to start' >&2; exit 7; }
        printf '%s\n' "$$" > "${FAKE_SERVER_PID:?}"
        echo 'fake server started'
        trap 'exit 0' TERM INT
        while :; do sleep 0.1; done ;;
      'status server')
        count=$(( $(cat "${FAKE_STATUS_COUNT:?}" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$count" > "$FAKE_STATUS_COUNT"
        if (( count <= ${FAKE_NOT_READY_POLLS:-1} )) || [[ ! -f ${FAKE_SERVER_PID:?} ]] || ! kill -0 "$(< "$FAKE_SERVER_PID")" 2>/dev/null; then
          echo '{"status":"stopped","running":false}'
        else
          echo '{"status":"running","running":true,"version":"0.8.2","protocol":20}'
        fi ;;
      'workspace list')
        if [[ ${FAKE_WORKSPACES:-0} == 1 ]]; then
          echo '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"label":"saved","workspace_id":"w1"}]}}'
        else
          echo '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[]}}'
        fi ;;
      'workspace create')
        echo '{"id":"cli:workspace:create","result":{"root_pane":{"agent_status":"unknown","cwd":"/x","focused":true,"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"},"tab":{"tab_id":"w1:t1"},"type":"workspace_created","workspace":{"label":"firstmate","workspace_id":"w1"}}}' ;;
      'pane run') exit 0 ;;
      'client ') printf 'client attached in %s\n' "$PWD" ;;
      *) echo "unexpected herdr call: $*" >&2; exit 2 ;;
    esac
  BASH

  FAKE_SQUEUE = <<~'BASH'
    #!/usr/bin/env bash
    [[ ${SQUEUE_FAIL:-0} == 0 ]] || exit 1
    case " $* " in
      *' -u '*) printf '%s\n' "${FAKE_USER_ROWS:-}" ;;
      *) printf '%s\n' "${FAKE_JOB_ROW:-}" ;;
    esac
  BASH

  class Context < OpenStruct
    def context
      self
    end

    def render_binding
      binding
    end
  end

  def setup
    @tmp = Dir.mktmpdir("ae-test-")
    @root = Pathname.new(@tmp).realpath
    @stage = @root.join("stage dir")
    @fm_home = @root.join("first mate's home")
    @home = @root.join("home")
    @run_root = @root.join("run")
    @bin = @root.join("bin")
    [@stage, @fm_home, @home, @run_root, @bin].each(&:mkpath)
    @fm_home.join("AGENTS.md").write("# Firstmate\n")
    @herdr = @root.join("fake herdr")
    write_exec(@herdr, FAKE_HERDR)
    write_exec(@bin.join("squeue"), FAKE_SQUEUE)
    write_exec(@bin.join("srun"), "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\" > \"$SRUN_LOG\"\nexit \"${SRUN_EXIT:-0}\"\n")
    write_exec(@bin.join("hostname"), "#!/usr/bin/env bash\nprintf '%s\\n' \"$FAKE_NODE\"\n")
    %w[claude codex pi].each { |name| write_exec(@bin.join(name), "#!/usr/bin/env bash\nexit 0\n") }
    @squeue_only = @root.join("squeue-only")
    @squeue_only.mkpath
    %w[squeue hostname].each { |name| FileUtils.cp(@bin.join(name), @squeue_only.join(name)) }
    bashenv = @root.join("bashenv")
    bashenv.write("module() { printf '%s\\n' \"$*\" >> \"$MODULE_LOG\"; [[ \" $* \" != *\" ${MODULE_FAIL:-__none__} \"* ]]; }\n")
    @env = {
      "PATH" => "#{@bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME" => @home.to_s, "TMPDIR" => @tmp,
      "BASH_ENV" => bashenv.to_s, "SLURM_JOB_ID" => JOB, "SLURMD_NODENAME" => NODE, "FAKE_NODE" => NODE,
      "FAKE_JOB_ROW" => "#{JOB}|#{USER}|RUNNING|#{NODE}", "FAKE_USER_ROWS" => "",
      "MODULE_LOG" => @root.join("modules").to_s, "HERDR_LOG" => @root.join("herdr.log").to_s,
      "SRUN_LOG" => @root.join("srun").to_s, "FAKE_SERVER_PID" => @root.join("server.pid").to_s,
      "FAKE_STATUS_COUNT" => @root.join("status.count").to_s,
      "AGENTIC_ENGINEERING_HERDR_BIN" => @herdr.to_s, "AGENTIC_ENGINEERING_RUNTIME_ROOT" => @run_root.to_s,
      "AGENTIC_ENGINEERING_READY_TIMEOUT" => "6"
    }
    @job_pid = nil
  end

  def teardown
    stop_job("KILL") if @job_pid
    FileUtils.remove_entry(@tmp)
  end

  def write_exec(path, body)
    path.write(body)
    path.chmod(0o755)
  end

  def render(name, values = {})
    path = APP.join(name)
    assert path.exist?, "missing app template #{name}"
    erb = ERB.new(path.read, trim_mode: "-")
    erb.filename = path.to_s
    erb.result(Context.new(DEFAULTS.merge(values)).render_binding)
  end

  def render_yaml(name, values = {})
    YAML.safe_load(render(name, values))
  end

  def socket_path
    "#{@run_root}/sherlock-agentic-engineering-#{Process.uid}-#{JOB}/herdr.sock"
  end

  def herdr_calls
    log = @root.join("herdr.log")
    log.exist? ? log.read.lines.map { |line| line.chomp.split("|", 3) } : []
  end

  def herdr_args
    herdr_calls.map(&:last)
  end

  def reset_logs
    %w[herdr.log modules srun server.pid status.count job.log].each do |name|
      path = @root.join(name)
      path.delete if path.exist?
    end
    %w[ae-ready ae-failed ae-restored ae-socket ae-startup.log herdr-server.log].each do |name|
      path = @stage.join(name)
      path.delete if path.exist?
    end
  end

  def stage_app(values = {})
    reset_logs
    values = { ae_home: @fm_home.to_s }.merge(values)
    %w[before.sh script.sh after.sh attach.sh].each do |name|
      @stage.join(name).write(render("template/#{name}.erb", values))
    end
    [@stage.join("script.sh"), @stage.join("attach.sh")].each { |path| path.chmod(0o700) }
    out, err, status = Open3.capture3(@env, "bash", "-c", 'clean_up() { exit "${1:-1}"; }; source "$1" && env -0', "bash",
                                      @stage.join("before.sh").to_s, chdir: @stage.to_s, unsetenv_others: true)
    assert status.success?, "before.sh failed: #{out}\n#{err}"
    out.split("\0").each do |item|
      key, value = item.split("=", 2)
      next if value.nil? || key.start_with?("BASH_FUNC_")
      @env[key] = value
    end
  end

  def source_before(values = {}, env = {})
    %w[before.sh].each { |name| @stage.join(name).write(render("template/#{name}.erb", values)) }
    Open3.capture3(@env.merge(env), "bash", "-c", 'clean_up() { exit "${1:-1}"; }; source "$1" && printf "home=%s" "$ae_home"', "bash",
                   @stage.join("before.sh").to_s, chdir: @stage.to_s, unsetenv_others: true)
  end

  def start_job(env = {})
    @job_log = @root.join("job.log")
    @job_pid = Process.spawn(@env.merge(env), "bash", @stage.join("script.sh").to_s, chdir: @stage.to_s,
                             out: @job_log.to_s, err: @job_log.to_s, unsetenv_others: true)
    deadline = Time.now + 20
    while Time.now < deadline
      return :ready if @stage.join("ae-ready").exist?
      if @stage.join("ae-failed").exist?
        assert wait_job, "a failed job must exit after marking ae-failed"
        return :failed
      end
      if Process.waitpid(@job_pid, Process::WNOHANG)
        @job_status = $CHILD_STATUS
        @job_pid = nil
        return @stage.join("ae-failed").exist? ? :failed : :exited
      end
      sleep 0.05
    end
    :timeout
  end

  def wait_job(limit = 15)
    deadline = Time.now + limit
    while Time.now < deadline
      if Process.waitpid(@job_pid, Process::WNOHANG)
        @job_status = $CHILD_STATUS
        @job_pid = nil
        return true
      end
      sleep 0.05
    end
    false
  end

  def stop_job(signal = "TERM")
    return unless @job_pid
    Process.kill(signal, @job_pid)
    unless wait_job
      Process.kill("KILL", @job_pid)
      wait_job(5)
    end
  end

  def source_after
    Open3.capture3(@env, "bash", "-c", 'set +e +u; clean_up() { exit "${1:-1}"; }; source "$1"; printf "restored=%s" "$ae_restored"', "bash",
                   @stage.join("after.sh").to_s, chdir: @stage.to_s, unsetenv_others: true)
  end

  def startup_log
    path = @stage.join("ae-startup.log")
    path.exist? ? path.read : ""
  end

  def attach(arg = JOB, env = {})
    Open3.capture3(@env.merge(env), "bash", @stage.join("attach.sh").to_s, *Array(arg), chdir: @stage.to_s, unsetenv_others: true)
  end

  # --- rendering -----------------------------------------------------------

  def test_manifest_and_form_describe_the_app
    manifest = YAML.safe_load(APP.join("manifest.yml").read)
    assert_equal "Agentic Engineering", manifest.fetch("name")
    assert_equal "batch_connect", manifest.fetch("role")
    assert_equal "Development", manifest.fetch("subcategory")

    form = render_yaml("form.yml.erb")
    assert_equal "sherlock", form.fetch("cluster")
    assert_equal %w[ae_session ae_harness ae_home bc_queue sh_cpus sh_mem bc_num_hours sh_modules bc_email_on_started], form.fetch("form")
    refute_includes form.fetch("form"), "sh_preexec"
    assert_equal "agentic-engineering", form.dig("attributes", "ae_session", "value")
    assert_equal "claude", form.dig("attributes", "ae_harness", "value")
    assert_equal %w[claude codex pi none], form.dig("attributes", "ae_harness", "options").map(&:last)
    assert_equal "$HOME/firstmate", form.dig("attributes", "ae_home", "value")
    assert_equal true, form.dig("attributes", "ae_home", "data-filepicker")
    assert_equal [%w[russpold russpold], %w[normal normal]], form.dig("attributes", "bc_queue", "options")
    assert_equal [8, 32, 8], %w[sh_cpus sh_mem bc_num_hours].map { |key| form.dig("attributes", key, "value") }
    assert APP.join("form.js").symlink?, "the directory picker needs _common/form.js"
    assert APP.join("form.js").exist?
    assert APP.join("template/script.sh.erb").executable?
    assert APP.join("template/attach.sh.erb").executable?
  end

  def test_submit_names_the_slurm_job_after_the_session_and_validates_fields
    submit = render_yaml("submit.yml.erb", sh_cpus: "12", sh_mem: "48", ae_session: "lab.session_2")
    assert_equal "basic", submit.dig("batch_connect", "template")
    assert_equal %w[ae_session ae_harness ae_home ae_job_id ae_host ae_user ae_staging_dir ae_restored], submit.dig("batch_connect", "conn_params")
    assert_equal ["-N", "1", "-c", "12", "--mem", "48G"], submit.dig("script", "native")
    assert_equal "sh_agentic-engineering/lab.session_2", submit.dig("script", "job_name")
    refute_includes submit.dig("script", "native"), "-p"
    refute_includes submit.dig("script", "native"), "-t"

    invalid = { sh_cpus: %w[0 -1 eight], sh_mem: %w[0 32G], bc_num_hours: %w[0 169 oops],
                bc_queue: %w[dev owners], ae_harness: %w[bash gemini],
                ae_session: ["bad name", ".", "..", "../x", "-leading", "a" * 65, "x;touch PWNED"] }
    invalid.each do |field, values|
      values.each do |value|
        assert_raises(ArgumentError, "#{field}=#{value.inspect} must be rejected") { render("submit.yml.erb", field => value) }
      end
    end
    render_yaml("submit.yml.erb", ae_session: "a" * 64, bc_num_hours: "168")
  end

  def test_view_escapes_values_and_shows_the_attach_command
    values = { ae_session: "lab", ae_harness: "codex", ae_home: "/home/u/first mate's home",
               ae_job_id: "42<x", ae_host: "sh03-01n01<x", ae_user: "u&me",
               ae_staging_dir: "/stage dir/<out>", ae_restored: "0" }
    view = render("view.html.erb", values)
    assert_includes view, "lab"
    assert_includes view, "42&lt;x"
    assert_includes view, "sh03-01n01&lt;x"
    assert_includes view, "u&amp;me"
    refute_includes view, "42<x"
    refute_includes view, "<out>"
    assert_includes view, "Codex was started"
    command = "bash -l /stage\\ dir/\\<out\\>/attach.sh 42\\<x"
    assert_includes view, ERB::Util.html_escape(command)
    assert_includes view, 'href="/pun/sys/shell/ssh/default"'
    refute_match(/\/rnode\/|password|<script/i, view)

    assert_includes render("view.html.erb", values.merge(ae_restored: "1")), "restored this session"
    assert_includes render("view.html.erb", values.merge(ae_harness: "none")), "No harness was started"
  end

  # --- before hook ---------------------------------------------------------

  def test_before_hook_expands_home_prefix_literally_and_rejects_bad_input
    out, _err, status = source_before({ ae_home: "$HOME/first mate's home" }, "HOME" => @root.to_s)
    assert status.success?, out
    assert_equal "home=#{@fm_home}", out

    _out, err, status = source_before(ae_home: "$(touch PWNED)/x")
    refute status.success?
    assert_includes err, "not an accessible directory"
    refute @stage.join("PWNED").exist?
    refute @root.join("PWNED").exist?

    _out, err, status = source_before({ ae_home: @fm_home.to_s }, "SLURM_JOB_ID" => "")
    refute status.success?
    assert_includes err, "numeric Slurm job ID"

    assert_raises(RuntimeError) { render("template/before.sh.erb", ae_session: "x;touch PWNED") }
    assert_raises(RuntimeError) { render("template/attach.sh.erb", ae_session: "bad name") }
    assert_raises(RuntimeError) { render("template/script.sh.erb", ae_harness: "bash") }
  end

  # --- lifecycle -----------------------------------------------------------

  def test_fresh_session_starts_server_workspace_and_harness_then_cleans_up
    stage_app(sh_modules: "python/3.12 'literal;touch PWNED'")
    rows = ["#{JOB}|RUNNING|#{MARKER}", "99999|PENDING|#{MARKER}", "777|RUNNING|sh_herdr/agentic-engineering"].join("\n")
    assert_equal :ready, start_job("FAKE_USER_ROWS" => rows), startup_log

    assert_equal JOB, @stage.join("ae-job-id").read.strip
    assert_equal NODE, @stage.join("ae-host").read.strip
    assert_equal 0o600, @stage.join("ae-job-id").stat.mode & 0o777
    assert_equal socket_path, @stage.join("ae-socket").read.strip
    runtime_dir = Pathname.new(socket_path).dirname
    assert runtime_dir.directory?
    assert_equal 0o700, runtime_dir.stat.mode & 0o777
    refute @stage.join("ae-restored").exist?

    modules = @root.join("modules").read.lines.map(&:chomp)
    assert_equal ["reset", "load system git", "load claude-code", "load python/3.12 literal;touch PWNED"], modules
    refute @fm_home.join("PWNED").exist?
    refute @stage.join("PWNED").exist?

    calls = herdr_calls
    assert calls.all? { |session, socket, _| session == "agentic-engineering" && socket == socket_path }, calls.inspect
    args = herdr_args
    assert_includes args, "server"
    assert_includes args, "status server --json"
    assert_includes args, "workspace list"
    assert_includes args, "workspace create --cwd #{@fm_home} --label first mate's home --no-focus"
    assert_includes args, "pane run w1:p1 claude"
    assert_operator args.count("status server --json"), :>=, 2, "readiness was polled until running"
    assert_match(/Started claude in pane w1:p1/, startup_log)

    out, err, status = source_after
    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "restored=0"

    stop_job("TERM")
    assert_equal 143, @job_status.exitstatus
    assert_includes herdr_args, "server stop"
    refute @stage.join("ae-ready").exist?
    refute runtime_dir.exist?, "cleanup removes only this job's runtime directory"
    assert @fm_home.directory?
    server_pid = @root.join("server.pid").read.to_i
    assert_raises(Errno::ESRCH) { Process.kill(0, server_pid) }
  end

  def test_restored_session_keeps_saved_layout_and_starts_nothing_new
    stage_app
    assert_equal :ready, start_job("FAKE_WORKSPACES" => "1"), startup_log
    assert @stage.join("ae-restored").exist?
    refute herdr_args.any? { |line| line.start_with?("workspace create", "pane run") }
    out, _err, status = source_after
    assert status.success?
    assert_includes out, "restored=1"
    stop_job("TERM")
  end

  def test_shell_only_session_creates_workspace_without_running_a_harness
    stage_app(ae_harness: "none")
    assert_equal :ready, start_job, startup_log
    assert_equal ["reset", "load system git"], @root.join("modules").read.lines.map(&:chomp)
    assert herdr_args.any? { |line| line.start_with?("workspace create") }
    refute herdr_args.any? { |line| line.start_with?("pane run") }
    stop_job("TERM")
  end

  def test_each_harness_loads_its_sherlock_module
    { "codex" => "codex", "pi" => "pi-coding-agent" }.each do |harness, mod|
      stage_app(ae_harness: harness)
      assert_equal :ready, start_job, startup_log
      assert_includes @root.join("modules").read.lines.map(&:chomp), "load #{mod}"
      assert_includes herdr_args, "pane run w1:p1 #{harness}"
      stop_job("TERM")
    end
  end

  def test_startup_failures_are_reported_before_any_server_starts
    cases = {
      "owned by an older job" => [{}, { "FAKE_USER_ROWS" => "100|RUNNING|#{MARKER}\n#{JOB}|RUNNING|#{MARKER}" }, "already owned by your Slurm job 100 (RUNNING)"],
      "squeue failure" => [{}, { "SQUEUE_FAIL" => "1" }, "Could not query Slurm"],
      "missing Herdr" => [{}, { "AGENTIC_ENGINEERING_HERDR_BIN" => "#{@root}/missing herdr" }, "Herdr is not installed at"],
      "module failure" => [{}, { "MODULE_FAIL" => "claude-code" }, "Could not load the claude-code module"],
      "extra module failure" => [{ sh_modules: "cuda/12" }, { "MODULE_FAIL" => "cuda/12" }, "Could not load the additional modules"],
      "missing harness" => [{ ae_harness: "pi" }, { "PATH" => "#{@squeue_only}:/usr/bin:/bin:/usr/sbin:/sbin" }, "pi command is unavailable"]
    }
    cases.each do |label, (values, env, message)|
      stage_app(values)
      assert_equal :failed, start_job(env), "#{label}: #{startup_log}"
      assert_includes startup_log, message, label
      refute herdr_args.include?("server"), "#{label}: no server may start"
      refute @stage.join("ae-ready").exist?, label
      out, err, status = source_after
      refute status.success?, "#{label}: after hook must fail"
      assert_includes err, message, "#{label}: after hook prints the startup log"
      assert_includes out + err, "startup failed", label
    end
  end

  def test_missing_agents_md_points_at_the_public_setup
    plain = @root.join("plain dir")
    plain.mkpath
    stage_app(ae_home: plain.to_s)
    assert_equal :failed, start_job, startup_log
    assert_includes startup_log, "has no AGENTS.md"
    assert_includes startup_log, "https://github.com/lobennett/agentic-engineering"
    refute herdr_args.include?("server")
  end

  def test_server_exit_before_readiness_fails_and_removes_runtime_dir
    stage_app
    assert_equal :failed, start_job("FAKE_SERVER_EXIT" => "1"), startup_log
    assert_includes startup_log, "Herdr server exited before becoming ready"
    assert_includes startup_log, "fake server refused to start"
    refute Pathname.new(socket_path).dirname.exist?
    _out, err, status = source_after
    refute status.success?
    assert_includes err, "fake server refused to start"
  end

  def test_server_death_ends_the_job_and_cleans_up
    stage_app
    assert_equal :ready, start_job, startup_log
    Process.kill("TERM", @root.join("server.pid").read.to_i)
    assert wait_job(12), "the job must exit once its Herdr server is gone"
    refute @job_status.success?
    assert_includes startup_log, "Herdr server stopped while the Slurm job was active"
    refute @stage.join("ae-ready").exist?
    refute Pathname.new(socket_path).dirname.exist?
  end

  # --- attach helper -------------------------------------------------------

  def test_attach_binds_an_srun_step_to_the_recorded_job
    stage_app
    @stage.join("ae-socket").write("#{socket_path}\n")
    out, err, status = attach(JOB, "SLURM_JOB_ID" => nil)
    assert status.success?, "#{out}\n#{err}"
    srun = @root.join("srun").read.lines.map(&:chomp)
    assert_equal ["--jobid=#{JOB}", "--overlap", "--nodes=1", "--ntasks=1", "--nodelist=#{NODE}", "--pty", "env",
                  "HERDR_SESSION=agentic-engineering", "HERDR_SOCKET_PATH=#{socket_path}", @herdr.to_s, "client"], srun

    @root.join("srun").delete
    out, err, status = attach(JOB, "SLURM_JOB_ID" => JOB)
    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "client attached"
    refute @root.join("srun").exist?, "inside the allocation the client runs directly"
    assert_includes herdr_calls.last, socket_path
  end

  def test_attach_rejects_wrong_jobs_states_nodes_and_contexts
    stage_app
    @stage.join("ae-socket").write("#{socket_path}\n")
    rejections = {
      "no argument" => [[], {}, "Usage"],
      "other job" => [["67890"], {}, "different Slurm job"],
      "pending" => [[JOB], { "FAKE_JOB_ROW" => "#{JOB}|#{USER}|PENDING|#{NODE}" }, "not RUNNING"],
      "foreign user" => [[JOB], { "FAKE_JOB_ROW" => "#{JOB}|someone|RUNNING|#{NODE}" }, "belong to you"],
      "other node" => [[JOB], { "FAKE_JOB_ROW" => "#{JOB}|#{USER}|RUNNING|sh03-01n02" }, "different node"],
      "malformed row" => [[JOB], { "FAKE_JOB_ROW" => "#{JOB}|#{USER}|RUNNING|#{NODE}|extra" }, "invalid record"],
      "missing job" => [[JOB], { "FAKE_JOB_ROW" => "" }, "missing"],
      "squeue failure" => [[JOB], { "SQUEUE_FAIL" => "1" }, "Could not verify"],
      "inside Herdr" => [[JOB], { "HERDR_ENV" => "1" }, "nested Herdr"],
      "missing Herdr" => [[JOB], { "AGENTIC_ENGINEERING_HERDR_BIN" => "/missing/herdr" }, "not installed"]
    }
    rejections.each do |label, (args, env, message)|
      out, err, status = attach(args, { "SLURM_JOB_ID" => nil }.merge(env))
      refute status.success?, label
      assert_includes err, message, label
      refute @root.join("srun").exist?, "#{label}: srun must not run"
      assert_empty out, label
    end

    @stage.join("ae-socket").write("/tmp/elsewhere/herdr.sock\n")
    _out, err, status = attach
    refute status.success?
    assert_includes err, "socket path is invalid"
    @stage.join("ae-socket").delete
    _out, err, status = attach
    refute status.success?
    assert_includes err, "has not finished starting"
  end
end
