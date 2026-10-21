#!/usr/bin/env ruby
require 'erb'
require 'ostruct'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'cgi'
require 'minitest/autorun'

class MarimoTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  DEFAULTS = { marimo_python: '$HOME/.local/share/sherlock-marimo/venv/bin/python',
               sh_workspace: '$HOME', sh_modules: '', sh_cpus: '8', sh_mem: '32',
               sh_gpus: '', sh_features: '', bc_queue: 'russpold', bc_num_hours: 8,
               host: 'sh-01.int', port: '12345', password: 'a' * 32 }.freeze

  def render(name, values = {})
    path = File.join(ROOT, name)
    assert File.file?(path), "missing app template #{name}"
    data = OpenStruct.new(DEFAULTS.merge(values))
    data.context = data
    erb = ERB.new(File.read(path), trim_mode: '-')
    erb.filename = path
    erb.result(data.instance_eval { binding })
  end

  def test_resources_render_as_individual_arguments_and_reject_bad_numbers
    config = YAML.safe_load(render('submit.yml.erb', sh_features: 'a"], "--evil', sh_gpus: '2'))
    assert_equal 'basic', config.dig('batch_connect', 'template')
    assert_equal ['-N', '1', '-c', '8', '--mem', '32G', '-G', '2', '--constraint', 'a"], "--evil'], config.dig('script', 'native')
    %w[0 -1 1x].each do |bad|
      assert_raises(ArgumentError) { render('submit.yml.erb', sh_cpus: bad) }
      assert_raises(ArgumentError) { render('submit.yml.erb', sh_mem: bad) }
      assert_raises(ArgumentError) { render('submit.yml.erb', sh_gpus: bad) }
    end
  end

  def test_form_exposes_runtime_and_workspace_without_raw_shell_commands
    form = YAML.safe_load(render('form.yml.erb'))
    %w[marimo_python sh_workspace bc_queue sh_cpus sh_mem bc_num_hours].each do |key|
      assert_includes form.fetch('form'), key
    end
    refute_includes form.fetch('form'), 'sh_preexec'
    assert_equal 'sherlock', form.fetch('cluster')
    assert File.symlink?(File.join(ROOT, 'form.js'))
    assert File.exist?(File.join(ROOT, 'form.js'))
  end

  def test_connection_submits_secret_in_post_body_and_escapes_html
    view = render('view.html.erb', password: %q[a<&"'], host: 'node"<unsafe')
    assert_includes view, 'method="post"'
    assert_includes view, '/node/node%22%3Cunsafe/12345/auth/login'
    assert_includes view, 'value="a&lt;&amp;&quot;&#39;"'
    refute_includes view, 'access_token='
    refute_includes view, '<script'
    refute_includes view, 'node"<unsafe'
  end

  def with_lifecycle(values = {})
    Dir.mktmpdir('marimo-test-') do |dir|
      workspace = File.join(dir, 'workspace; touch INJECTED')
      FileUtils.mkdir_p(workspace)
      python = File.join(dir, 'python executable')
      File.write(python, <<~'BASH')
        #!/usr/bin/env bash
        if [[ $* == *--help* ]]; then
          printf '%s\n' '--token-password-file --base-url --no-sandbox --skip-update-check'
          exit 0
        fi
        printf '%s\0' "$PWD" "$@" > "$RECORD"
      BASH
      FileUtils.chmod(0700, python)
      values = { sh_workspace: workspace, marimo_python: python }.merge(values)
      %w[before.sh.erb script.sh.erb after.sh.erb].each do |name|
        File.write(File.join(dir, name.sub('.erb', '')), render("template/#{name}", values))
      end
      FileUtils.chmod(0700, File.join(dir, 'script.sh'))
      yield dir, workspace
    end
  end

  def run_before(dir, extra = '')
    Open3.capture3({ 'RECORD' => File.join(dir, 'argv') }, 'bash', '-c', <<~BASH, chdir: dir)
      host=sh-01.int
      find_port() { printf '12345'; }
      create_passwd() { printf '%032d' 1; }
      module() { printf '%s\\0' "$@" >> modules; }
      export -f module
      options_before=$(set +o)
      source ./before.sh
      [[ $(set +o) == "$options_before" ]] || exit 91
      #{extra}
      ./script.sh
    BASH
  end

  def test_rendered_lifecycle_launches_authenticated_editor_in_literal_workspace
    with_lifecycle(sh_modules: 'python/3.12 "literal;touch INJECTED"') do |dir, workspace|
      out, err, status = run_before(dir)
      assert status.success?, "#{out}\n#{err}"
      argv = File.binread(File.join(dir, 'argv')).split("\0")
      assert_equal workspace, argv.shift
      assert_equal %w[-m marimo -q edit --headless --host 0.0.0.0 --port 12345 --base-url /node/sh-01.int/12345 --token --token-password-file], argv.shift(13)
      token_file = argv.shift
      assert_equal '00000000000000000000000000000001', File.read(token_file)
      assert_equal 0600, File.stat(token_file).mode & 0777
      assert_equal %w[--no-sandbox --skip-update-check], argv
      refute_includes out + err, File.read(token_file)
      refute File.exist?(File.join(dir, 'INJECTED'))
      assert_equal ['reset', 'load', 'python/3.12', 'literal;touch INJECTED'], File.binread(File.join(dir, 'modules')).split("\0")
    end
    assert File.executable?(File.join(ROOT, 'template/script.sh.erb'))
  end

  def test_missing_python_or_missing_marimo_fails_with_setup_guidance
    with_lifecycle(marimo_python: '/missing/python') do |dir, _|
      _, err, status = run_before(dir)
      refute status.success?
      assert_includes err, 'Python executable'
      refute File.exist?(File.join(dir, 'argv'))
    end
    with_lifecycle do |dir, _|
      File.write(File.join(dir, 'python executable'), "#!/usr/bin/env bash\necho 'No module named marimo' >&2\nexit 1\n")
      _, err, status = run_before(dir)
      refute status.success?
      assert_includes err, 'Install marimo'
    end
  end

  def test_missing_workspace_and_empty_password_never_start_server
    with_lifecycle(sh_workspace: '/missing/workspace') do |dir, _|
      _, err, status = run_before(dir)
      refute status.success?
      assert_includes err, 'Workspace'
      refute File.exist?(File.join(dir, 'argv'))
    end
    with_lifecycle do |dir, _|
      _, _, status = Open3.capture3('bash', '-c', 'host=sh-01.int; find_port() { echo 12345; }; create_passwd() { :; }; source ./before.sh', chdir: dir)
      refute status.success?
    end
  end

  def test_home_expansion_does_not_evaluate_command_substitution
    with_lifecycle do |dir, workspace|
      home_values = {marimo_python: '$HOME/python executable', sh_workspace: '$HOME/workspace; touch INJECTED'}
      File.write(File.join(dir, 'script.sh'), render('template/script.sh.erb', home_values))
      out, err, status = run_before(dir, 'export HOME="$PWD"')
      assert status.success?, "#{out}\n#{err}"
      assert_equal File.realpath(workspace), File.realpath(File.binread(File.join(dir, 'argv')).split("\0").first)
    end
    with_lifecycle(marimo_python: '$(touch INJECTED)/python') do |dir, _|
      _, _, status = run_before(dir)
      refute status.success?
      refute File.exist?(File.join(dir, 'INJECTED'))
    end
  end

  def test_sourced_hooks_preserve_strict_and_trace_settings_without_secret_leak
    with_lifecycle do |dir, _|
      out, err, status = Open3.capture3('bash', '-c', <<~'BASH', chdir: dir)
        set -euxo pipefail
        host=sh-01.int
        find_port() { printf '12345'; }
        create_passwd() { printf '%032d' 1; }
        source ./before.sh
        [[ $- == *e* && $- == *u* && $- == *x* ]]
        [[ $(set -o | awk '$1 == "pipefail" { print $2 }') == on ]]
        wait_until_port_used() { return 0; }
        source ./after.sh
        [[ $- == *e* && $- == *u* && $- == *x* ]]
      BASH
      assert status.success?, "#{out}\n#{err}"
      refute_includes out + err, '00000000000000000000000000000001'
    end
  end

  def test_incompatible_marimo_does_not_start
    with_lifecycle do |dir, _|
      File.write(File.join(dir, 'python executable'), "#!/usr/bin/env bash\necho '--base-url'\n")
      _, err, status = run_before(dir)
      refute status.success?
      assert_includes err, 'lacks --token-password-file'
      refute File.exist?(File.join(dir, 'argv'))
    end
  end

  def test_startup_failure_cleans_up_without_changing_wrapper_options
    with_lifecycle do |dir, _|
      out, err, status = Open3.capture3('bash', '-c', <<~'BASH', chdir: dir)
        host=sh-01.int port=12345 SCRIPT_PID=987654
        wait_until_port_used() { return 1; }
        pkill() { return 0; }
        kill() { printf '%s\n' "$*" > terminated; }
        clean_up() { exit "$1"; }
        source ./after.sh
      BASH
      refute status.success?, "#{out}\n#{err}"
      assert_includes out + err, 'Timed out'
      assert File.file?(File.join(dir, 'terminated')), 'the launcher itself must stop on timeout'
      assert_equal '987654', File.read(File.join(dir, 'terminated')).strip
    end
  end
end
