% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd_multipart).

-export([
    abort_multipart_stream/1,
    decode_multipart_stream/3,
    encode_multipart_stream/5,
    length_multipart_stream/3,
    num_mp_writers/0,
    num_mp_writers/1
]).

-include_lib("couch/include/couch_db.hrl").

decode_multipart_stream(ContentType, DataFun, Ref) ->
    Parent = self(),
    NumMpWriters = num_mp_writers(),
    {Parser, ParserRef} = spawn_monitor(fun() ->
        ParentRef = erlang:monitor(process, Parent),
        put(mp_parent_ref, ParentRef),
        num_mp_writers(NumMpWriters),
        {<<"--",_/binary>>, _, _} = parse_multipart_request(
            ContentType, DataFun,
            fun(Next) -> mp_parse_doc(Next, []) end),
        unlink(Parent)
        end),
    Parser ! {get_doc_bytes, Ref, self()},
    receive
    {started_open_doc_revs, NewRef} ->
        %% FIXME: How to remove the knowledge about this message?
        {{started_open_doc_revs, NewRef}, Parser, ParserRef};
    {doc_bytes, Ref, DocBytes}  ->
        {{doc_bytes, Ref, DocBytes}, Parser, ParserRef};
    {'DOWN', ParserRef, _, _, normal} ->
        ok;
    {'DOWN', ParserRef, process, Parser, {{nocatch, {Error, Msg}}, _}} ->
        couch_log:error("Multipart streamer ~p died with reason ~p",
                        [ParserRef, Msg]),
        throw({Error, Msg});
    {'DOWN', ParserRef, _, _, Reason} ->
        couch_log:error("Multipart streamer ~p died with reason ~p",
                        [ParserRef, Reason]),
        throw({error, Reason})
    end.


mp_parse_doc({headers, H}, []) ->
    case couch_util:get_value("content-type", H) of
    {"application/json", _} ->
        fun (Next) ->
            mp_parse_doc(Next, [])
        end;
    _ ->
        throw({bad_ctype, <<"Content-Type must be application/json">>})
    end;
mp_parse_doc({body, Bytes}, AccBytes) ->
    fun (Next) ->
        mp_parse_doc(Next, [Bytes | AccBytes])
    end;
mp_parse_doc(body_end, AccBytes) ->
    receive {get_doc_bytes, Ref, From} ->
        From ! {doc_bytes, Ref, lists:reverse(AccBytes)}
    end,
    fun(Next) ->
        mp_parse_atts(Next, {Ref, [], 0, orddict:new(), []})
    end.

mp_parse_atts({headers, _}, Acc) ->
    fun(Next) -> mp_parse_atts(Next, Acc) end;
mp_parse_atts(body_end, Acc) ->
    fun(Next) -> mp_parse_atts(Next, Acc) end;
mp_parse_atts({body, Bytes}, {Ref, Chunks, Offset, Counters, Waiting}) ->
    case maybe_send_data({Ref, Chunks++[Bytes], Offset, Counters, Waiting}) of
        abort_parsing ->
            fun(Next) -> mp_abort_parse_atts(Next, nil) end;
        NewAcc ->
            fun(Next) -> mp_parse_atts(Next, NewAcc) end
    end;
mp_parse_atts(eof, {Ref, Chunks, Offset, Counters, Waiting}) ->
    N = num_mp_writers(),
    M = length(Counters),
    case (M == N) andalso Chunks == [] of
    true ->
        ok;
    false ->
        ParentRef = get(mp_parent_ref),
        receive
        abort_parsing ->
            ok;
        {get_bytes, Ref, From} ->
            C2 = orddict:update_counter(From, 1, Counters),
            NewAcc = maybe_send_data({Ref, Chunks, Offset, C2, [From|Waiting]}),
            mp_parse_atts(eof, NewAcc);
        {'DOWN', ParentRef, _, _, _} ->
            exit(mp_reader_coordinator_died)
        after 3600000 ->
            ok
        end
    end.

mp_abort_parse_atts(eof, _) ->
    ok;
mp_abort_parse_atts(_, _) ->
    fun(Next) -> mp_abort_parse_atts(Next, nil) end.

maybe_send_data({Ref, Chunks, Offset, Counters, Waiting}) ->
    receive {get_bytes, Ref, From} ->
        NewCounters = orddict:update_counter(From, 1, Counters),
        maybe_send_data({Ref, Chunks, Offset, NewCounters, [From|Waiting]})
    after 0 ->
        % reply to as many writers as possible
        NewWaiting = lists:filter(fun(Writer) ->
            WhichChunk = orddict:fetch(Writer, Counters),
            ListIndex = WhichChunk - Offset,
            if ListIndex =< length(Chunks) ->
                Writer ! {bytes, Ref, lists:nth(ListIndex, Chunks)},
                false;
            true ->
                true
            end
        end, Waiting),

        % check if we can drop a chunk from the head of the list
        case Counters of
        [] ->
            SmallestIndex = 0;
        _ ->
            SmallestIndex = lists:min(element(2, lists:unzip(Counters)))
        end,
        Size = length(Counters),
        N = num_mp_writers(),
        if Size == N andalso SmallestIndex == (Offset+1) ->
            NewChunks = tl(Chunks),
            NewOffset = Offset+1;
        true ->
            NewChunks = Chunks,
            NewOffset = Offset
        end,

        % we should wait for a writer if no one has written the last chunk
        LargestIndex = lists:max([0|element(2, lists:unzip(Counters))]),
        if LargestIndex  >= (Offset + length(Chunks)) ->
            % someone has written all possible chunks, keep moving
            {Ref, NewChunks, NewOffset, Counters, NewWaiting};
        true ->
            ParentRef = get(mp_parent_ref),
            receive
            abort_parsing ->
                abort_parsing;
            {'DOWN', ParentRef, _, _, _} ->
                exit(mp_reader_coordinator_died);
            {get_bytes, Ref, X} ->
                C2 = orddict:update_counter(X, 1, Counters),
                maybe_send_data({Ref, NewChunks, NewOffset, C2, [X|NewWaiting]})
            end
        end
    end.


num_mp_writers(N) ->
    erlang:put(mp_att_writers, N).


num_mp_writers() ->
    case erlang:get(mp_att_writers) of
        undefined -> 1;
        Count -> Count
    end.

encode_multipart_stream(_Boundary, JsonBytes, [], WriteFun, _AttFun) ->
    WriteFun(JsonBytes);
encode_multipart_stream(Boundary, JsonBytes, Atts, WriteFun, AttFun) ->
    WriteFun([<<"--", Boundary/binary,
                "\r\nContent-Type: application/json\r\n\r\n">>,
              JsonBytes, <<"\r\n--", Boundary/binary>>]),
    atts_to_mp(Atts, Boundary, WriteFun, AttFun).

atts_to_mp([], _Boundary, WriteFun, _AttFun) ->
    WriteFun(<<"--">>);
atts_to_mp([{Att, Name, Len, Type, Encoding} | RestAtts], Boundary, WriteFun,
    AttFun)  ->
    LengthBin = list_to_binary(integer_to_list(Len)),
    % write headers
    WriteFun(<<"\r\nContent-Disposition: attachment; filename=\"", Name/binary, "\"">>),
    WriteFun(<<"\r\nContent-Type: ", Type/binary>>),
    WriteFun(<<"\r\nContent-Length: ", LengthBin/binary>>),
    case Encoding of
        identity ->
            ok;
        _ ->
            EncodingBin = atom_to_binary(Encoding, latin1),
            WriteFun(<<"\r\nContent-Encoding: ", EncodingBin/binary>>)
    end,

    % write data
    WriteFun(<<"\r\n\r\n">>),
    AttFun(Att, fun(Data, _) -> WriteFun(Data) end, ok),
    WriteFun(<<"\r\n--", Boundary/binary>>),
    atts_to_mp(RestAtts, Boundary, WriteFun, AttFun).

length_multipart_stream(Boundary, JsonBytes, Atts) ->
    AttsSize = lists:foldl(fun({_Att, Name, Len, Type, Encoding}, AccAttsSize) ->
          AccAttsSize +
          4 + % "\r\n\r\n"
          length(integer_to_list(Len)) +
          Len +
          4 + % "\r\n--"
          size(Boundary) +
          % attachment headers
          % (the length of the Content-Length has already been set)
          size(Name) +
          size(Type) +
          length("\r\nContent-Disposition: attachment; filename=\"\"") +
          length("\r\nContent-Type: ") +
          length("\r\nContent-Length: ") +
          case Encoding of
          identity ->
              0;
           _ ->
              length(atom_to_list(Encoding)) +
              length("\r\nContent-Encoding: ")
          end
        end, 0, Atts),
    if AttsSize == 0 ->
        {<<"application/json">>, iolist_size(JsonBytes)};
    true ->
        {<<"multipart/related; boundary=\"", Boundary/binary, "\"">>,
            2 + % "--"
            size(Boundary) +
            36 + % "\r\ncontent-type: application/json\r\n\r\n"
            iolist_size(JsonBytes) +
            4 + % "\r\n--"
            size(Boundary) +
            + AttsSize +
            2 % "--"
            }
    end.

abort_multipart_stream(Parser) ->
    MonRef = erlang:monitor(process, Parser),
    Parser ! abort_parsing,
    receive
        {'DOWN', MonRef, _, _, _} -> ok
    after 60000 ->
        % One minute is quite on purpose for this timeout. We
        % want to try and read data to keep the socket open
        % when possible but we also don't want to just make
        % this a super long timeout because people have to
        % wait this long to see if they just had an error
        % like a validate_doc_update failure.
        throw(multi_part_abort_timeout)
    end.

-record(mp, {boundary, buffer, data_fun, callback}).


parse_multipart_request(ContentType, DataFun, Callback) ->
    Boundary0 = iolist_to_binary(get_boundary(ContentType)),
    Boundary = <<"\r\n--", Boundary0/binary>>,
    Mp = #mp{boundary= Boundary,
            buffer= <<>>,
            data_fun=DataFun,
            callback=Callback},
    {Mp2, _NilCallback} = read_until(Mp, <<"--", Boundary0/binary>>,
        fun nil_callback/1),
    #mp{buffer=Buffer, data_fun=DataFun2, callback=Callback2} =
            parse_part_header(Mp2),
    {Buffer, DataFun2, Callback2}.

nil_callback(_Data)->
    fun nil_callback/1.

get_boundary({"multipart/" ++ _, Opts}) ->
    case couch_util:get_value("boundary", Opts) of
        S when is_list(S) ->
            S
    end;
get_boundary(ContentType) ->
    {"multipart/" ++ _ , Opts} = mochiweb_util:parse_header(ContentType),
    get_boundary({"multipart/", Opts}).



split_header(<<>>) ->
    [];
split_header(Line) ->
    {Name, Rest} = lists:splitwith(fun (C) -> C =/= $: end,
                                   binary_to_list(Line)),
    [$: | Value] = case Rest of
        [] ->
            throw({bad_request, <<"bad part header">>});
        Res ->
            Res
    end,
    [{string:to_lower(string:strip(Name)),
     mochiweb_util:parse_header(Value)}].

read_until(#mp{data_fun=DataFun, buffer=Buffer}=Mp, Pattern, Callback) ->
    case couch_util:find_in_binary(Pattern, Buffer) of
    not_found ->
        Callback2 = Callback(Buffer),
        {Buffer2, DataFun2} = DataFun(),
        Buffer3 = iolist_to_binary(Buffer2),
        read_until(Mp#mp{data_fun=DataFun2,buffer=Buffer3}, Pattern, Callback2);
    {partial, 0} ->
        {NewData, DataFun2} = DataFun(),
        read_until(Mp#mp{data_fun=DataFun2,
                buffer= iolist_to_binary([Buffer,NewData])},
                Pattern, Callback);
    {partial, Skip} ->
        <<DataChunk:Skip/binary, Rest/binary>> = Buffer,
        Callback2 = Callback(DataChunk),
        {NewData, DataFun2} = DataFun(),
        read_until(Mp#mp{data_fun=DataFun2,
                buffer= iolist_to_binary([Rest | NewData])},
                Pattern, Callback2);
    {exact, 0} ->
        PatternLen = size(Pattern),
        <<_:PatternLen/binary, Rest/binary>> = Buffer,
        {Mp#mp{buffer= Rest}, Callback};
    {exact, Skip} ->
        PatternLen = size(Pattern),
        <<DataChunk:Skip/binary, _:PatternLen/binary, Rest/binary>> = Buffer,
        Callback2 = Callback(DataChunk),
        {Mp#mp{buffer= Rest}, Callback2}
    end.


parse_part_header(#mp{callback=UserCallBack}=Mp) ->
    {Mp2, AccCallback} = read_until(Mp, <<"\r\n\r\n">>,
            fun(Next) -> acc_callback(Next, []) end),
    HeaderData = AccCallback(get_data),

    Headers =
    lists:foldl(fun(Line, Acc) ->
            split_header(Line) ++ Acc
        end, [], re:split(HeaderData,<<"\r\n">>, [])),
    NextCallback = UserCallBack({headers, Headers}),
    parse_part_body(Mp2#mp{callback=NextCallback}).

parse_part_body(#mp{boundary=Prefix, callback=Callback}=Mp) ->
    {Mp2, WrappedCallback} = read_until(Mp, Prefix,
            fun(Data) -> body_callback_wrapper(Data, Callback) end),
    Callback2 = WrappedCallback(get_callback),
    Callback3 = Callback2(body_end),
    case check_for_last(Mp2#mp{callback=Callback3}) of
    {last, #mp{callback=Callback3}=Mp3} ->
        Mp3#mp{callback=Callback3(eof)};
    {more, Mp3} ->
        parse_part_header(Mp3)
    end.

acc_callback(get_data, Acc)->
    iolist_to_binary(lists:reverse(Acc));
acc_callback(Data, Acc)->
    fun(Next) -> acc_callback(Next, [Data | Acc]) end.

body_callback_wrapper(get_callback, Callback) ->
    Callback;
body_callback_wrapper(Data, Callback) ->
    Callback2 = Callback({body, Data}),
    fun(Next) -> body_callback_wrapper(Next, Callback2) end.


check_for_last(#mp{buffer=Buffer, data_fun=DataFun}=Mp) ->
    case Buffer of
    <<"--",_/binary>> -> {last, Mp};
    <<_, _, _/binary>> -> {more, Mp};
    _ -> % not long enough
        {Data, DataFun2} = DataFun(),
        check_for_last(Mp#mp{buffer= <<Buffer/binary, Data/binary>>,
                data_fun = DataFun2})
    end.
