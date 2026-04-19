defmodule Reach.AshPluginTest do
  use ExUnit.Case, async: false

  setup do
    old = :persistent_term.get(:reach_effect_plugins, nil)
    :persistent_term.put(:reach_effect_plugins, [Reach.Plugins.Ash])

    if :ets.whereis(:reach_classify_cache) != :undefined do
      :ets.delete_all_objects(:reach_classify_cache)
    end

    on_exit(fn ->
      if old,
        do: :persistent_term.put(:reach_effect_plugins, old),
        else: :persistent_term.erase(:reach_effect_plugins)
    end)

    :ok
  end

  describe "effect classification" do
    test "Ash.create/create! classified as :write" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def make(attrs) do
              MyApp.Post
              |> Ash.Changeset.for_create(:create, attrs)
              |> Ash.create!()
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      create_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :create! and &1.meta[:module] == Ash))

      assert Reach.Effects.classify(create_node) == :write
    end

    test "Ash.read/read! classified as :read" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def list_all do
              MyApp.Post
              |> Ash.Query.for_read(:read)
              |> Ash.read!()
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      read_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :read! and &1.meta[:module] == Ash))

      assert Reach.Effects.classify(read_node) == :read
    end

    test "Ash.update!/destroy! classified as :write" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def do_update(record, attrs) do
              record
              |> Ash.Changeset.for_update(:update, attrs)
              |> Ash.update!()
            end

            def do_destroy(record) do
              record
              |> Ash.Changeset.for_destroy(:destroy)
              |> Ash.destroy!()
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      nodes = Reach.nodes(graph)

      update_node =
        Enum.find(nodes, &(&1.meta[:function] == :update! and &1.meta[:module] == Ash))

      destroy_node =
        Enum.find(nodes, &(&1.meta[:function] == :destroy! and &1.meta[:module] == Ash))

      assert Reach.Effects.classify(update_node) == :write
      assert Reach.Effects.classify(destroy_node) == :write
    end

    test "Ash.get!/exists? classified as :read" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def fetch(id) do
              Ash.get!(MyApp.Post, id)
            end

            def check(id) do
              Ash.exists?(MyApp.Post |> Ash.Query.filter(id: id))
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      nodes = Reach.nodes(graph)

      get_node =
        Enum.find(nodes, &(&1.meta[:function] == :get! and &1.meta[:module] == Ash))

      exists_node =
        Enum.find(nodes, &(&1.meta[:function] == :exists? and &1.meta[:module] == Ash))

      assert Reach.Effects.classify(get_node) == :read
      assert Reach.Effects.classify(exists_node) == :read
    end

    test "bulk operations classified as :write" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def bulk(records) do
              Ash.bulk_create!(records, MyApp.Post, :create)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      bulk_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :bulk_create! and &1.meta[:module] == Ash))

      assert Reach.Effects.classify(bulk_node) == :write
    end

    test "Ash.run_action classified as :io" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def run(input) do
              Ash.run_action!(input)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      run_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :run_action! and &1.meta[:module] == Ash))

      assert Reach.Effects.classify(run_node) == :io
    end

    test "Ash.Changeset functions classified as :pure" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def build(attrs) do
              MyApp.Post
              |> Ash.Changeset.for_create(:create, attrs)
              |> Ash.Changeset.change_attribute(:status, :active)
              |> Ash.Changeset.set_argument(:notify, true)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      nodes = Reach.nodes(graph)

      for_create =
        Enum.find(nodes, &(&1.meta[:function] == :for_create and &1.meta[:module] == Ash.Changeset))

      change_attr =
        Enum.find(
          nodes,
          &(&1.meta[:function] == :change_attribute and &1.meta[:module] == Ash.Changeset)
        )

      set_arg =
        Enum.find(
          nodes,
          &(&1.meta[:function] == :set_argument and &1.meta[:module] == Ash.Changeset)
        )

      assert Reach.Effects.classify(for_create) == :pure
      assert Reach.Effects.classify(change_attr) == :pure
      assert Reach.Effects.classify(set_arg) == :pure
    end

    test "Ash.Query functions classified as :pure" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def build_query do
              MyApp.Post
              |> Ash.Query.for_read(:read)
              |> Ash.Query.filter(status: :active)
              |> Ash.Query.sort(inserted_at: :desc)
              |> Ash.Query.load(:author)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      nodes = Reach.nodes(graph)

      for_read =
        Enum.find(nodes, &(&1.meta[:function] == :for_read and &1.meta[:module] == Ash.Query))

      filter =
        Enum.find(nodes, &(&1.meta[:function] == :filter and &1.meta[:module] == Ash.Query))

      sort =
        Enum.find(nodes, &(&1.meta[:function] == :sort and &1.meta[:module] == Ash.Query))

      ash_load =
        Enum.find(nodes, &(&1.meta[:function] == :load and &1.meta[:module] == Ash.Query))

      assert Reach.Effects.classify(for_read) == :pure
      assert Reach.Effects.classify(filter) == :pure
      assert Reach.Effects.classify(sort) == :pure
      assert Reach.Effects.classify(ash_load) == :pure
    end

    test "Ash.can? classified as :pure" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def check(user, post) do
              Ash.can?({MyApp.Post, :update}, user)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      can_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :can? and &1.meta[:module] == Ash))

      assert Reach.Effects.classify(can_node) == :pure
    end

    test "Resource DSL macros classified as :pure" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp.Post do
            attribute :title, :string
            uuid_primary_key :id
            belongs_to :author, MyApp.Author
            has_many :comments, MyApp.Comment
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      nodes = Reach.nodes(graph)

      attr_node = Enum.find(nodes, &(&1.meta[:function] == :attribute))
      pk_node = Enum.find(nodes, &(&1.meta[:function] == :uuid_primary_key))
      bt_node = Enum.find(nodes, &(&1.meta[:function] == :belongs_to))
      hm_node = Enum.find(nodes, &(&1.meta[:function] == :has_many))

      assert Reach.Effects.classify(attr_node) == :pure
      assert Reach.Effects.classify(pk_node) == :pure
      assert Reach.Effects.classify(bt_node) == :pure
      assert Reach.Effects.classify(hm_node) == :pure
    end
  end

  describe "changeset to CRUD edges" do
    test "connects Ash.Changeset.for_create to Ash.create!" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def create_post(attrs) do
              MyApp.Post
              |> Ash.Changeset.for_create(:create, attrs)
              |> Ash.create!()
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      flow_edges = Enum.filter(edges, &match?({:ash_changeset_flow, _}, &1.label))

      assert length(flow_edges) == 1

      [edge] = flow_edges
      assert edge.label == {:ash_changeset_flow, :create}

      cs_node =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.meta[:function] == :for_create and &1.meta[:module] == Ash.Changeset)
        )

      create_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :create! and &1.meta[:module] == Ash))

      assert edge.v1 == cs_node.id
      assert edge.v2 == create_node.id
    end

    test "connects for_update to Ash.update!" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def update_post(post, attrs) do
              post
              |> Ash.Changeset.for_update(:update, attrs)
              |> Ash.update!()
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      flow_edges = Enum.filter(edges, &match?({:ash_changeset_flow, _}, &1.label))

      assert length(flow_edges) == 1
      assert hd(flow_edges).label == {:ash_changeset_flow, :update}
    end
  end

  describe "query to read edges" do
    test "connects Ash.Query.for_read to Ash.read!" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def list_posts do
              MyApp.Post
              |> Ash.Query.for_read(:read)
              |> Ash.Query.filter(status: :published)
              |> Ash.read!()
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      query_edges = Enum.filter(edges, &(&1.label == :ash_query_flow))

      assert query_edges != []

      read_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :read! and &1.meta[:module] == Ash))

      assert Enum.all?(query_edges, &(&1.v2 == read_node.id))
    end
  end

  describe "form submit edges" do
    test "connects AshPhoenix.Form.for_create to submit" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyLive do
            def handle_event("save", params, socket) do
              form = AshPhoenix.Form.for_create(MyApp.Post, :create)
              AshPhoenix.Form.submit(form, params: params)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      form_edges = Enum.filter(edges, &(&1.label == :ash_form_submit))

      assert length(form_edges) == 1

      [edge] = form_edges

      form_node =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.meta[:function] == :for_create and &1.meta[:module] == AshPhoenix.Form)
        )

      submit_node =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.meta[:function] == :submit and &1.meta[:module] == AshPhoenix.Form)
        )

      assert edge.v1 == form_node.id
      assert edge.v2 == submit_node.id
    end

    test "AshPhoenix.Form.validate classified as :pure" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyLive do
            def handle_event("validate", params, socket) do
              AshPhoenix.Form.validate(socket.assigns.form, params)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      validate_node =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.meta[:function] == :validate and &1.meta[:module] == AshPhoenix.Form)
        )

      assert Reach.Effects.classify(validate_node) == :pure
    end

    test "AshPhoenix.Form.submit classified as :write" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyLive do
            def save(form) do
              AshPhoenix.Form.submit(form)
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      submit_node =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.meta[:function] == :submit and &1.meta[:module] == AshPhoenix.Form)
        )

      assert Reach.Effects.classify(submit_node) == :write
    end
  end

  describe "cross-module edges" do
    test "connects DSL change reference to change/3 implementation" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp.Changes.Slugify do
            def change(changeset, _opts, _context) do
              changeset
            end
          end

          defmodule MyApp.Post do
            def actions do
              change MyApp.Changes.Slugify
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      change_edges = Enum.filter(edges, &(&1.label == :ash_change_dispatch))

      assert length(change_edges) == 1

      [edge] = change_edges

      impl =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.type == :function_def and &1.meta[:name] == :change and
              &1.meta[:arity] in [3, 4])
        )

      assert edge.v2 == impl.id
    end

    test "connects DSL validate reference to validate/2 implementation" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp.Validations.CheckName do
            def validate(changeset, _opts) do
              :ok
            end
          end

          defmodule MyApp.Post do
            def actions do
              validate MyApp.Validations.CheckName
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      val_edges = Enum.filter(edges, &(&1.label == :ash_validation_dispatch))

      assert length(val_edges) == 1

      [edge] = val_edges

      impl =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.type == :function_def and &1.meta[:name] == :validate and
              &1.meta[:arity] in [2, 3])
        )

      assert edge.v2 == impl.id
    end

    test "connects DSL prepare reference to prepare/3 implementation" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp.Preparations.FilterActive do
            def prepare(query, _opts, _context) do
              query
            end
          end

          defmodule MyApp.Post do
            def actions do
              prepare MyApp.Preparations.FilterActive
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      prep_edges = Enum.filter(edges, &(&1.label == :ash_preparation_dispatch))

      assert length(prep_edges) == 1

      [edge] = prep_edges

      impl =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.type == :function_def and &1.meta[:name] == :prepare and
              &1.meta[:arity] in [3, 4])
        )

      assert edge.v2 == impl.id
    end

    test "connects code_interface define to matching action" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp.Blog do
            def interface do
              define :create_post, action: :create
              define :list_posts, action: :list
            end
          end

          defmodule MyApp.Post do
            def actions do
              create :create do
                accept [:title]
              end

              read :list do
                prepare build(sort: :title)
              end
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      ci_edges = Enum.filter(edges, &match?({:ash_code_interface, _}, &1.label))

      assert length(ci_edges) >= 1
    end
  end

  describe "action input to run_action edges" do
    test "connects Ash.ActionInput to Ash.run_action" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp do
            def analyze(text) do
              MyApp.Post
              |> Ash.ActionInput.for_action(:analyze_text, %{text: text})
              |> Ash.run_action!()
            end
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      edges = Reach.edges(graph)
      input_edges = Enum.filter(edges, &(&1.label == :ash_action_input_flow))

      assert length(input_edges) == 1

      [edge] = input_edges

      input_node =
        Reach.nodes(graph)
        |> Enum.find(
          &(&1.meta[:function] == :for_action and &1.meta[:module] == Ash.ActionInput)
        )

      run_node =
        Reach.nodes(graph)
        |> Enum.find(&(&1.meta[:function] == :run_action! and &1.meta[:module] == Ash))

      assert edge.v1 == input_node.id
      assert edge.v2 == run_node.id
    end
  end

  describe "state machine DSL" do
    test "transition DSL classified as :pure" do
      graph =
        Reach.string_to_graph!(
          """
          defmodule MyApp.Order do
            transition :submit, from: :draft, to: :pending
            transition :approve, from: :pending, to: :approved
          end
          """,
          plugins: [Reach.Plugins.Ash]
        )

      nodes = Reach.nodes(graph)
      transition_nodes = Enum.filter(nodes, &(&1.meta[:function] == :transition))

      for node <- transition_nodes do
        assert Reach.Effects.classify(node) == :pure
      end
    end
  end
end
