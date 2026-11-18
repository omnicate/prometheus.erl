-module(prometheus_collector_global_labels_test).

-include("prometheus_model.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([collect_mf/2, collect_metrics/2, deregister_cleanup/1]).

deregister_cleanup(_) ->
    ok.

collect_mf(_Registry, Callback) ->
    Callback(
        prometheus_model_helpers:create_mf(
            <<"prerendered_mf">>,
            <<"Help text">>,
            counter,
            ?MODULE,
            {counter_prerendered, 5}
        )
    ),
    Callback(
        prometheus_model_helpers:create_mf(
            <<"regular_mf">>,
            <<"Help text">>,
            counter,
            ?MODULE,
            {counter, 5}
        )
    ),
    Callback(
        prometheus_model_helpers:create_mf(
            <<"no_label_mf">>,
            <<"Help text">>,
            counter,
            ?MODULE,
            {counter_no_label, 5}
        )
    ),

    %% Empty binary can be a sign of an empty pre-rendered list
    Callback(
        prometheus_model_helpers:create_mf(
            <<"no_label_prerendered_mf">>,
            <<"Help text">>,
            counter,
            ?MODULE,
            {counter_no_label_prerendered, 5}
        )
    ),
    ok.

collect_metrics(_, {counter_no_label, Value}) ->
    [prometheus_model_helpers:counter_metric([], Value)];
collect_metrics(_, {counter_no_label_prerendered, Value}) ->
    [prometheus_model_helpers:counter_metric(<<>>, Value)];
collect_metrics(_, {counter_prerendered, Value}) ->
    [prometheus_model_helpers:counter_metric(<<"label=\"prerendered\"">>, Value)];
collect_metrics(_, {_, Value}) ->
    [prometheus_model_helpers:counter_metric([{label, regular}], Value)].

global_labels_prerendering_test() ->
    MFList =
        try
            prometheus:start(),
            prometheus_registry:register_collectors([?MODULE]),
            application:set_env(prometheus, global_labels, [{node, some_value1}]),
            prometheus_collector:collect_mf_to_list(?MODULE)
        after
            application:unset_env(prometheus, global_labels),
            prometheus_registry:deregister_collector(?MODULE)
        end,
    ?assertEqual(
        [[<<"node=\"some_value1\",label=\"prerendered\"">>]], get_labels(MFList, prerendered_mf)
    ),
    ?assertEqual(
        [
            [
                [
                    #'LabelPair'{name = <<"node">>, value = <<"some_value1">>},
                    #'LabelPair'{name = <<"label">>, value = <<"regular">>}
                ]
            ]
        ],
        get_labels(MFList, regular_mf)
    ),
    ok.

empty_global_labels_prerendering_test() ->
    MFList =
        try
            prometheus:start(),
            prometheus_registry:register_collectors([?MODULE]),
            application:set_env(prometheus, global_labels, []),
            prometheus_collector:collect_mf_to_list(?MODULE)
        after
            application:unset_env(prometheus, global_labels),
            prometheus_registry:deregister_collector(?MODULE)
        end,
    ?assertEqual([[[]]], get_labels(MFList, no_label_mf)),
    ok.

empty_labels_plus_global_labels_prerendering_test() ->
    MFList =
        try
            prometheus:start(),
            prometheus_registry:register_collectors([?MODULE]),
            application:set_env(prometheus, global_labels, [{node, some_value2}]),
            prometheus_collector:collect_mf_to_list(?MODULE)
        after
            application:unset_env(prometheus, global_labels),
            prometheus_registry:deregister_collector(?MODULE)
        end,
    ?assertEqual([[<<"node=\"some_value2\"">>]], get_labels(MFList, no_label_prerendered_mf)),
    ok.

metric_family_filter_runs_before_global_labels_test() ->
    MFList =
        try
            prometheus:start(),
            prometheus_registry:register_collectors([?MODULE]),
            application:set_env(prometheus, global_labels, [{node, some_value3}]),
            ok = prometheus_collector:set_metric_family_filter(
                fun
                    (
                        #'MetricFamily'{
                            name = <<"regular_mf">>, metric = [#'Metric'{label = Labels}]
                        }
                    ) ->
                        ?assertEqual(
                            [#'LabelPair'{name = <<"label">>, value = <<"regular">>}],
                            Labels
                        ),
                        drop;
                    (MF) ->
                        MF
                end
            ),
            prometheus_collector:collect_mf_to_list(?MODULE)
        after
            ok = prometheus_collector:set_metric_family_filter(undefined),
            application:unset_env(prometheus, global_labels),
            prometheus_registry:deregister_collector(?MODULE)
        end,
    ?assertEqual([], get_labels(MFList, regular_mf)),
    ?assertEqual(
        [[[#'LabelPair'{name = <<"node">>, value = <<"some_value3">>}]]],
        get_labels(MFList, no_label_mf)
    ),
    ok.

metric_family_filter_survives_env_reload_test() ->
    Env = application:get_all_env(prometheus),
    MFList =
        try
            ok = prometheus_collector:set_metric_family_filter(fun(_MF) -> drop end),
            lists:foreach(fun({Key, _}) -> application:unset_env(prometheus, Key) end, Env),
            prometheus_collector:collect_mf_to_list(?MODULE)
        after
            lists:foreach(
                fun({Key, Value}) -> application:set_env(prometheus, Key, Value) end, Env
            ),
            ok = prometheus_collector:set_metric_family_filter(undefined)
        end,
    ?assertEqual([], MFList),
    ok.

metric_family_filter_can_be_removed_test() ->
    ok = prometheus_collector:set_metric_family_filter(fun(_MF) -> drop end),
    ok = prometheus_collector:set_metric_family_filter(undefined),
    MFList = prometheus_collector:collect_mf_to_list(?MODULE),
    ?assertEqual(
        [[[#'LabelPair'{name = <<"label">>, value = <<"regular">>}]]],
        get_labels(MFList, regular_mf)
    ),
    ok.

metric_family_filter_rejects_invalid_values_test() ->
    ?assertError(function_clause, prometheus_collector:set_metric_family_filter(not_a_function)),
    try
        ok = prometheus_collector:set_metric_family_filter(fun(_MF) -> not_a_metric_family end),
        ?assertError(
            {invalid_metric_family_filter_result, not_a_metric_family},
            prometheus_collector:collect_mf_to_list(?MODULE)
        )
    after
        ok = prometheus_collector:set_metric_family_filter(undefined)
    end.

get_labels(MFList, MFName) ->
    MFNameB = atom_to_binary(MFName, latin1),
    lists:filtermap(
        fun
            (#'MetricFamily'{name = MFName1, metric = Metrics}) when MFName1 =:= MFNameB ->
                {true, [Label || #'Metric'{label = Label} <- Metrics]};
            (_) ->
                false
        end,
        MFList
    ).
