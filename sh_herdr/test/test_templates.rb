#!/usr/bin/env ruby

require "erb"
require "open3"
require "ostruct"
require "yaml"
require "minitest/autorun"

class String
  def blank?
    strip.empty?
  end
end

class NilClass
  def blank?
    true
  end
end

class TemplateBinding
  attr_accessor :herdr_session, :herdr_agents, :herdr_workspace, :sh_workspace,
                :bc_queue, :sh_cpus, :sh_mem, :bc_num_hours, :sh_modules,
                :sh_preexec, :bc_email_on_started, :herdr_job_id

  def initialize(values = {})
    @herdr_session = values.fetch(:herdr_session, "sherlock")
    @herdr_agents = values.fetch(:herdr_agents, "both")
    @herdr_workspace = values.fetch(:herdr_workspace, "$HOME")
    @sh_workspace = values.fetch(:sh_workspace, "$HOME")
    @bc_queue = values.fetch(:bc_queue, "russpold")
    @sh_cpus = values[:sh_cpus]
    @sh_mem = values[:sh_mem]
    @bc_num_hours = values.fetch(:bc_num_hours, 8)
    @sh_modules = values.fetch(:sh_modules, "")
    @sh_preexec = values.fetch(:sh_preexec, "")
    @bc_email_on_started = values.fetch(:bc_email_on_started, false)
    @herdr_job_id = values.fetch(:herdr_job_id, "12345")
  end

  def get_binding
    binding
  end

  def context
    self
  end

  def session
    self
  end
end

class TemplateTest < Minitest::Test
  APP_ROOT = File.expand_path("../..", __dir__)

  def render(template, values = {})
    path = File.join(APP_ROOT, template)
    renderer = ERB.new(File.read(path), trim_mode: "-")
    renderer.filename = path
    renderer.result(TemplateBinding.new(values).get_binding)
  end

  def render_connection_view(values = {})
    path = File.join(APP_ROOT, "sh_herdr/view.html.erb")
    renderer = ERB.new(File.read(path), trim_mode: "-")
    renderer.filename = path
    renderer.result(OpenStruct.new(values).instance_eval { binding })
  end

  def test_job_template_is_executable_by_open_ondemand
    template = File.join(APP_ROOT, "sh_herdr/template/script.sh.erb")

    assert File.executable?(template), "Open OnDemand executes the staged job template directly"
  end

  def test_form_defaults_and_partition_options
    form = YAML.safe_load(render("sh_herdr/form.yml.erb"))
    assert_equal "sherlock", form.fetch("cluster")
    assert_equal %w[
      herdr_session
      herdr_agents
      sh_workspace
      bc_queue
      sh_cpus
      sh_mem
      bc_num_hours
      sh_modules
      sh_preexec
      bc_email_on_started
    ], form.fetch("form")
    assert_equal "sherlock", form.dig("attributes", "herdr_session", "value")
    assert_equal "both", form.dig("attributes", "herdr_agents", "value")
    assert_equal [["Both", "both"], ["Claude", "claude"], ["Codex", "codex"], ["None", "none"]],
                 form.dig("attributes", "herdr_agents", "options")
    assert_equal "russpold", form.dig("attributes", "bc_queue", "value")
    assert_equal [["russpold", "russpold"], ["normal", "normal"]],
                 form.dig("attributes", "bc_queue", "options")
    assert_equal 8, form.dig("attributes", "sh_cpus", "value")
    assert_equal 32, form.dig("attributes", "sh_mem", "value")
    assert_equal 8, form.dig("attributes", "bc_num_hours", "value")

    %w[herdr_session herdr_agents sh_workspace bc_queue sh_cpus sh_mem bc_num_hours].each do |field|
      assert_equal true, form.dig("attributes", field, "required"), "#{field} must be required"
    end
  end

  def test_submit_template_uses_basic_connection_and_resources
    submit = YAML.safe_load(render("sh_herdr/submit.yml.erb", sh_cpus: "12", sh_mem: "48"))
    assert_equal "basic", submit.dig("batch_connect", "template")
    assert_equal %w[herdr_session herdr_workspace herdr_job_id], submit.dig("batch_connect", "conn_params")
    assert_equal ["-N", "1", "-c", "12", "--mem", "48G"], submit.dig("script", "native")
    refute_includes submit.dig("script", "native"), "-p"
    refute_includes submit.dig("script", "native"), "--partition"
    refute_includes submit.dig("script", "native"), "-t"
    refute_includes submit.dig("script", "native"), "--time"

    defaults = YAML.safe_load(render("sh_herdr/submit.yml.erb"))
    assert_equal ["-N", "1", "-c", "8", "--mem", "32G"], defaults.dig("script", "native")
  end

  def test_submit_template_rejects_non_positive_or_non_numeric_resources
    %w[0 -1 sixteen].each do |invalid_cpu|
      submit = YAML.safe_load(render("sh_herdr/submit.yml.erb", sh_cpus: invalid_cpu, sh_mem: "48"))
      assert_equal ["-N", "1", "-c", "8", "--mem", "48G"], submit.dig("script", "native"),
                   "CPU #{invalid_cpu.inspect} must fall back to 8"
    end

    %w[0 -1 forty-eight].each do |invalid_mem|
      submit = YAML.safe_load(render("sh_herdr/submit.yml.erb", sh_cpus: "12", sh_mem: invalid_mem))
      assert_equal ["-N", "1", "-c", "12", "--mem", "32G"], submit.dig("script", "native"),
                   "memory #{invalid_mem.inspect} must fall back to 32G"
    end
  end

  def test_manifest_identifies_the_batch_connect_app
    manifest = YAML.safe_load(File.read(File.join(APP_ROOT, "sh_herdr/manifest.yml")))
    assert_equal "Herdr", manifest.fetch("name")
    assert_equal "Interactive Apps", manifest.fetch("category")
    assert_equal "Development", manifest.fetch("subcategory")
    assert_equal "batch_connect", manifest.fetch("role")
    assert_includes manifest.fetch("description"), "persistent agent workspace"
  end

  def test_form_has_only_supported_resource_choices
    form = YAML.safe_load(render("sh_herdr/form.yml.erb"))
    refute_includes form.fetch("form"), "sh_gpus"
    assert_equal({
      "label" => "Initial workspace",
      "help" => "Choose the directory used for Herdr's initial workspace.",
      "required" => true,
      "data-filepicker" => true,
      "data-target-file-type" => "dirs",
      "data-default-directory" => "$HOME",
      "readonly" => true,
      "value" => "$HOME"
    }, form.dig("attributes", "sh_workspace"))
    assert_includes form.dig("attributes", "sh_preexec", "label"), "Advanced"
    assert_includes form.dig("attributes", "sh_preexec", "help"), "execute as the user"
  end

  def test_lifecycle_templates_render_a_private_persistent_session
    values = {
      herdr_session: "sherlock",
      herdr_agents: "both",
      sh_workspace: "/home/users/test/work"
    }

    before_script = render("sh_herdr/template/before.sh.erb", values)
    job_script = render("sh_herdr/template/script.sh.erb", values)
    after_script = render("sh_herdr/template/after.sh.erb", values)
    view = File.read(File.join(APP_ROOT, "sh_herdr/view.html.erb"))

    assert_includes before_script, "export herdr_session=sherlock"
    assert_includes before_script, "export herdr_workspace=/home/users/test/work"
    assert_includes before_script, 'export herdr_job_id="${SLURM_JOB_ID:-}"'
    assert_includes before_script, "export herdr_staging_dir=\"$PWD\""
    assert_includes job_script, "module load claude-code codex"
    assert_includes job_script, "HERDR_SESSION"
    assert_includes job_script, "HERDR_SOCKET_PATH"
    assert_includes job_script, 'herdr_bin=${SHERLOCK_HERDR_BIN:-$HOME/.local/bin/herdr}'
    assert_includes job_script, '[[ -x $herdr_bin ]]'
    refute_includes job_script, "command -v herdr"
    refute_includes job_script, "--session"
    assert_includes job_script, '[[ $status_json == \{* && $status_json == *\} && ( $status_json == *\'"running":true,\'* || $status_json == *\'"running":true}\' ) ]]'
    refute_match(/\bruby\b/, job_script)
    assert_includes job_script, "herdr_staging_dir"
    assert_includes after_script, "herdr-ready"
    assert_includes after_script, "herdr_staging_dir"
    assert_includes view, "sherlock-herdr"
    assert_includes view, "herdr_job_id.to_s"
    refute_includes view, "/rnode/"
    refute_match(/<form|https?:\/\/|password/i, view)
  end

  def test_rendered_scripts_escape_form_values_without_disabling_raw_initialization
    values = {
      herdr_session: "sherlock; touch session-pwned",
      herdr_agents: "both; touch agent-pwned",
      sh_workspace: "/home/users/test/work; touch workspace-pwned",
      sh_modules: "safe-module; touch module-pwned",
      sh_preexec: "printf 'intentional raw initialization\\n'"
    }

    before_script = render("sh_herdr/template/before.sh.erb", values)
    job_script = render("sh_herdr/template/script.sh.erb", values)

    assert_includes before_script, "sherlock\\;\\ touch\\ session-pwned"
    assert_includes before_script, "workspace-pwned"
    assert_includes job_script, "both\\;\\ touch\\ agent-pwned"
    assert_includes job_script, "safe-module\\; touch"
    assert_includes job_script, "printf 'intentional raw initialization"
    _output, status = Open3.capture2("bash", "-n", stdin_data: "#{before_script}\n#{job_script}")
    assert status.success?, "rendered lifecycle shell must parse"

    view = render("sh_herdr/view.html.erb", values.merge(herdr_job_id: "42<unsafe"))
    assert_includes view, "42&lt;unsafe"
    refute_includes view, "42<unsafe"
  end

  def test_view_escapes_all_display_values_and_includes_one_time_setup_instruction
    view = render_connection_view(
      herdr_session: "session<unsafe",
      herdr_workspace: "/work/<unsafe",
      herdr_job_id: "42<unsafe"
    )

    assert_includes view, "session&lt;unsafe"
    assert_includes view, "/work/&lt;unsafe"
    assert_includes view, "42&lt;unsafe"
    assert_includes view, "sherlock-herdr 42&lt;unsafe"
    assert_includes view, "setup"
    refute_match(/<form|\/rnode\/|https?:\/\/|password/i, view)
  end
end
