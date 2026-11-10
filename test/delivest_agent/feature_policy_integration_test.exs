defmodule DelivestAgent.FeaturePolicyIntegrationTest do
  use ExUnit.Case, async: false

  alias DelivestAgent.{FakeRunner, Project}
  alias DelivestAgent.FullBackup.FeaturePolicy

  @tag skip: System.get_env("DELIVEST_POLICY_INTEGRATION") != "1"
  test "staging keeps target flags and audit, fences generations, and cancels only optional jobs" do
    suffix = System.unique_integer([:positive]) |> Integer.to_string()
    target = "policy_target_#{suffix}"
    stage = "policy_stage_#{suffix}"

    try do
      for database <- [target, stage] do
        assert {_, 0} =
                 docker(["exec", "delivest-postgres", "createdb", "-U", "postgres", database])

        assert {_, 0} = psql(database, schema_sql())
      end

      branch = "11111111-1111-1111-1111-111111111111"
      removed = "22222222-2222-2222-2222-222222222222"
      assert {_, 0} = psql(stage, "INSERT INTO branches VALUES ('#{branch}',NULL);")

      assert {_, 0} =
               psql(target, """
               INSERT INTO feature_gates VALUES
                 ('segments','franchise',false,7,now(),now()),
                 ('segments','branch:#{removed}',true,9,now(),now());
               INSERT INTO feature_audits(id,feature,scope_key,enabled,generation,actor,inserted_at)
                 VALUES (5,'segments','franchise',false,7,'host',now());
               """)

      assert {_, 0} =
               psql(stage, """
               INSERT INTO feature_gates VALUES
                 ('segments','franchise',true,99,now(),now()),
                 ('segments','branch:#{branch}',true,100,now(),now());
               INSERT INTO feature_audits(id,feature,scope_key,enabled,generation,actor,inserted_at)
                 VALUES (8,'segments','franchise',true,99,'archive',now());
               INSERT INTO background_schedules(kind,scope_key) VALUES ('segments.refresh','franchise');
               INSERT INTO oban_jobs(worker,state) VALUES
                 ('Delivest.Background.Runner','available'),
                 ('Delivest.Background.Dispatcher','executing'),
                 ('Delivest.Payments.Worker','available');
               """)

      FakeRunner.stub(fn "docker", args ->
        ["exec", "-T", "postgres" | command] = Enum.drop_while(args, &(&1 != "exec"))

        docker([
          "exec",
          "-e",
          "POSTGRES_DB=#{target}",
          "-e",
          "POSTGRES_USER=postgres",
          "delivest-postgres" | command
        ])
      end)

      project = %Project{name: "scratch", dir: "/tmp", files: [], agent_service: "agent"}
      assert :ok = FeaturePolicy.preserve(project, stage, suffix)

      {rows, 0} =
        psql(stage, """
        SELECT scope_key || ':' || enabled || ':' || generation FROM feature_gates ORDER BY scope_key;
        SELECT id || ':' || actor FROM feature_audits;
        SELECT nextval('feature_audits_id_seq');
        SELECT worker || ':' || state FROM oban_jobs ORDER BY id;
        SELECT count(*) FROM background_schedules;
        """)

      assert rows =~ "franchise:false:101"
      refute rows =~ "branch:#{removed}"
      refute rows =~ "archive"
      assert rows =~ "5:host"
      assert rows =~ "6\n"
      assert rows =~ "Delivest.Background.Runner:cancelled"
      assert rows =~ "Delivest.Background.Dispatcher:cancelled"
      assert rows =~ "Delivest.Payments.Worker:available"
      assert String.ends_with?(String.trim(rows), "0")
    after
      for database <- [target, stage],
          do:
            docker([
              "exec",
              "delivest-postgres",
              "dropdb",
              "-U",
              "postgres",
              "--if-exists",
              database
            ])
    end
  end

  defp schema_sql do
    """
    CREATE TABLE branches(id uuid PRIMARY KEY, deleted_at timestamp);
    CREATE TABLE feature_gates(feature text, scope_key text, enabled boolean, generation bigint,
      inserted_at timestamp, updated_at timestamp, PRIMARY KEY(feature,scope_key));
    CREATE TABLE feature_audits(id bigserial PRIMARY KEY, feature text, scope_key text,
      enabled boolean, generation bigint, actor text, inserted_at timestamp);
    CREATE TABLE background_schedules(id bigserial PRIMARY KEY, kind text, scope_key text);
    CREATE TABLE oban_jobs(id bigserial PRIMARY KEY, worker text, state text, cancelled_at timestamp);
    """
  end

  defp psql(database, sql),
    do:
      docker([
        "exec",
        "delivest-postgres",
        "psql",
        "-U",
        "postgres",
        "-d",
        database,
        "-Atqc",
        sql
      ])

  defp docker(args), do: System.cmd("docker", args, stderr_to_stdout: true)
end
