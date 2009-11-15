%%%-------------------------------------------------------------------
%%% File    : s3.erl
%%% Author  : Andrew Birkett <andy@nobugs.org> 
%%%         : Seven Du <seven .at. idapted.com>
%%% Description : 
%%%
%%% Created : 14 Nov 2007 by Andrew Birkett <andy@nobugs.org>
%%%-------------------------------------------------------------------
-module(s3).

-behaviour(gen_server).

%% API
-export([ start/1, download_object/2, download_object/3, has_key/2,
	  list_buckets/0, create_bucket/1, delete_bucket/1,
	  list_objects/2, list_objects/1, write_object/4, read_object/2, delete_object/2 ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
	 terminate/2, code_change/3]).

-include_lib("xmerl/include/xmerl.hrl").
-include("s3.hrl").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start(AwsCredentials) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, AwsCredentials, []).

create_bucket (Name) -> gen_server:call(?MODULE, {put, Name} ).
delete_bucket (Name) -> gen_server:call(?MODULE, {delete, Name} ).
list_buckets ()      -> gen_server:call(?MODULE, {listbuckets}).         


write_object (Bucket, Key, Data, ContentType) -> 
    gen_server:call(?MODULE, {put, Bucket, Key, Data, ContentType}).
read_object (Bucket, Key) -> 
    gen_server:call(?MODULE, {get, Bucket, Key}, 600000).
download_object (Bucket, Key) -> 
    download_object(Bucket, Key, []).
download_object (Bucket, Key, Options) -> 
    gen_server:call(?MODULE, {download, Bucket, Key, Options}, 600000).
delete_object (Bucket, Key) -> 
    gen_server:call(?MODULE, {delete, Bucket, Key}).
has_key (Bucket, Key) -> 
    case gen_server:call(?MODULE, {head, Bucket, Key}) of
		{ok, _, _} -> true;
		_ -> false
	end.

%% option example: [{delimiter, "/"},{maxresults,10},{prefix,"/foo"}]
list_objects (Bucket, Options ) -> gen_server:call(?MODULE, {list, Bucket, Options }).
list_objects (Bucket) -> list_objects( Bucket, [] ).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init(AwsCredentials) -> 
	io:format("init s3~n"),
    crypto:start(),
    % inets:start(),
    {ok, AwsCredentials}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

% Bucket operations
handle_call({listbuckets}, _From, AwsCredentials) ->
    { reply, xmlToBuckets(getRequest( AwsCredentials, "", "", [] )), AwsCredentials };

handle_call({ put, Bucket }, _From, AwsCredentials) ->
    {ok,_Headers,_Body} = putRequest( AwsCredentials,Bucket, "", <<>>, ""),
    { reply, {ok}, AwsCredentials };

handle_call({delete, Bucket }, _From, AwsCredentials) ->
    try 
	{ok,_Headers,_Body} = deleteRequest( AwsCredentials, Bucket, ""),
	{ reply, {ok}, AwsCredentials }
    catch
	throw:X -> { reply, X, AwsCredentials }
    end;

% Object operations
handle_call({put, Bucket, Key, Content, ContentType }, _From, AwsCredentials) ->
    {ok,Headers,_Body} = putRequest( AwsCredentials,Bucket, Key, Content, ContentType),
    {value,{"etag",ETag}} = lists:keysearch( "etag", 1, Headers ),
    {reply, {ok, ETag}, AwsCredentials};

handle_call({ list, Bucket, Options }, _From, AwsCredentials) ->
    Headers = lists:map( fun option_to_param/1, Options ),
    {ok, _, Body} = getRequest( AwsCredentials, Bucket, "", Headers ),
    {reply, parseBucketListXml(Body), AwsCredentials};

handle_call({ get, Bucket, Key }, _From, AwsCredentials) ->
    {reply, getRequest( AwsCredentials, Bucket, Key, [] ), AwsCredentials};

handle_call({ head, Bucket, Key }, _From, AwsCredentials) ->
    {reply, headRequest( AwsCredentials, Bucket, Key, [] ), AwsCredentials};

handle_call({ download, Bucket, Key, Options }, _From, AwsCredentials) ->
    {reply, downloadRequest( AwsCredentials, Bucket, Key, Options ), AwsCredentials};

handle_call({ stream, Bucket, Key, Options }, From, AwsCredentials) ->
    {reply, streamRequest( From, AwsCredentials, Bucket, Key, Options ), AwsCredentials};

handle_call({delete, Bucket, Key }, _From, AwsCredentials) ->
    try 
	{ok,_Headers,_Body} = deleteRequest( AwsCredentials, Bucket, Key),
	{reply, {ok}, AwsCredentials}
    catch
	throw:X -> { reply, X, AwsCredentials }
    end.
       
%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->  
	io:format("handle cast: ~p~n", [_Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
	io:format("handle info~p|~p~n", [_Info, State]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

s3Host () ->
    "s3.amazonaws.com".

option_to_param( { prefix, X } ) -> 
    { "prefix", X };
option_to_param( { maxkeys, X } ) -> 
    { "max-keys", integer_to_list(X) };
option_to_param( { delimiter, X } ) -> 
    { "delimiter", X }.

headRequest( AwsCredentials, Bucket, Key, Headers ) ->
    genericRequest( AwsCredentials, head, Bucket, Key, Headers, <<>>, "" ).
getRequest( AwsCredentials, Bucket, Key, Headers ) ->    
    genericRequest( AwsCredentials, get, Bucket, Key, Headers, <<>>, "" ).
putRequest( AwsCredentials, Bucket, Key, Content, ContentType ) ->
    genericRequest( AwsCredentials, put, Bucket, Key, [], Content, ContentType ).
deleteRequest( AwsCredentials, Bucket, Key ) ->
    genericRequest( AwsCredentials, delete, Bucket, Key, [], <<>>, "" ).


downloadRequest( AwsCredentials, Bucket, Key, Options ) ->
    {Url, Headers, _Body} = buildS3Headers(AwsCredentials, get, Bucket, Key, [], <<>>, ""),
    
	Options1 = case proplists:get_value(save_response_to_file, Options) of
		undefined -> [{save_response_to_file, true} | Options];
		_ -> Options
	end,                                      
	
	% Reply = ibrowse:send_req(Url, Headers, get, Body, Options1),
	Reply = ibrowse:send_req(Url, Headers, get, [], Options1),
    
    case Reply of
		{ok, Code, ResponseHeaders, ResponseBody } 
	 	when Code=:="200"; Code=:="204" ->
	    	{ok,ResponseHeaders,ResponseBody};

		{ok, _Code, _ResponseHeaders, ResponseBody } ->   
			parseErrorXml(ResponseBody)
    end.

streamRequest( From, AwsCredentials, Bucket, Key, Options ) ->
    {Url, Headers, _Body} = buildS3Headers(AwsCredentials, get, Bucket, Key, [], <<>>, ""),
    
	{Pid, _} = From,
	Options1 = case proplists:get_value(stream_to, Options) of
		undefined -> [{stream_to, Pid}, {stream_chunk_size, 4096} | Options];
		_ -> Options
	end,                                      
	                                                  
	% {ibrowse_req_id, ReqId}
	ibrowse:send_req(Url, Headers, get, [], Options1).
        

isAmzHeader( Header ) -> lists:prefix("x-amz-", Header).

canonicalizedAmzHeaders( AllHeaders ) ->
    AmzHeaders = [ {string:to_lower(K),V} || {K,V} <- AllHeaders, isAmzHeader(K) ],
    Strings = lists:map( 
		fun s3util:join/1, 
		s3util:collapse( 
		  lists:keysort(1, AmzHeaders) ) ),
    s3util:string_join( lists:map( fun (S) -> S ++ "\n" end, Strings), "").
    
canonicalizedResource ( "", "" ) -> "/";
canonicalizedResource ( Bucket, "" ) -> "/" ++ Bucket ++ "/";
canonicalizedResource ( Bucket, Path ) -> "/" ++ Bucket ++ "/" ++ Path.

stringToSign ( Verb, ContentMD5, ContentType, Date, Bucket, Path, OriginalHeaders ) ->
    Parts = [ Verb, ContentMD5, ContentType, Date, canonicalizedAmzHeaders(OriginalHeaders)],
    s3util:string_join( Parts, "\n") ++ canonicalizedResource(Bucket, Path).
    
sign (Key,Data) ->
%    io:format("Data being signed is ~p~n", [Data]),
    binary_to_list( base64:encode( crypto:sha_mac(Key,Data) ) ).

queryParams( [] ) -> "";
queryParams( L ) -> 
    Stringify = fun ({K,V}) -> K ++ "=" ++ V end,
    "?" ++ s3util:string_join( lists:map( Stringify, L ), "&" ).

buildHost("") -> s3Host();
buildHost(Bucket) -> Bucket ++ "." ++ s3Host().
    
buildUrl(Bucket,Path,QueryParams) -> 
    "http://" ++ buildHost(Bucket) ++ "/" ++ Path ++ queryParams(QueryParams).

buildContentHeaders( <<>>, _ ) -> [];
buildContentHeaders( Contents, ContentType ) -> 
    [{"Content-Length", integer_to_list(size(Contents))},
     {"Content-Type", ContentType}].


buildS3Headers( AwsCredentials, Method, Bucket, Path, QueryParams, Contents, ContentType ) ->
    Date = httpd_util:rfc1123_date(),
    MethodString = string:to_upper( atom_to_list(case Method of download -> get; _ -> Method end) ),

	Url = buildUrl(Bucket,Path,QueryParams),

    OriginalHeaders = buildContentHeaders( Contents, ContentType ),
    ContentMD5 = "",
    Body = Contents,

    #aws_credentials{ accessKeyId=AKI, secretAccessKey=SAK } = AwsCredentials,

    Signature = sign( SAK,
		      stringToSign( MethodString, ContentMD5, ContentType, 
				    Date, Bucket, Path, OriginalHeaders )),	
    Headers = [ {"Authorization","AWS " ++ AKI ++ ":" ++ Signature },
		{"Host", buildHost(Bucket) },
		{"Date", Date } 
	       | OriginalHeaders],
	{Url, Headers, Body}.

                
genericRequest( AwsCredentials, Method, Bucket, Path, QueryParams, Contents, ContentType ) ->

    {Url, Headers, _Body} = buildS3Headers(AwsCredentials, Method, Bucket, Path, QueryParams, Contents, ContentType ),

	Reply = ibrowse:send_req(Url, Headers, Method),
    
    case Reply of
		{ok, Code, ResponseHeaders, ResponseBody } 
	 	when Code=:="200"; Code=:="204" ->
	    	{ok,ResponseHeaders,ResponseBody};

		{ok, Code, _ResponseHeaders, ResponseBody } ->   
		case ResponseBody of
			[] -> {s3error, Code, "NoSuchKey"};
			_ -> parseErrorXml(ResponseBody)
		end
    end.


parseBucketListXml (Xml) ->
    {XmlDoc, _Rest} = xmerl_scan:string( Xml ),
    ContentNodes = xmerl_xpath:string("/ListBucketResult/Contents", XmlDoc),

    GetObjectAttribute = fun (Node,Attribute) -> 
		      [Child] = xmerl_xpath:string( Attribute, Node ),
		      {Attribute, s3util:string_value( Child )}
	      end,

    NodeToRecord = fun (Node) ->
			   #object_info{ 
			 key =          GetObjectAttribute(Node,"Key"),
			 lastmodified = GetObjectAttribute(Node,"LastModified"),
			 etag =         GetObjectAttribute(Node,"ETag"),
			 size =         GetObjectAttribute(Node,"Size")}
		   end,
    { ok, lists:map( NodeToRecord, ContentNodes ) }.

parseErrorXml (Xml) ->
    {XmlDoc, _Rest} = xmerl_scan:string( Xml ),
    [#xmlText{value=ErrorCode}]    = xmerl_xpath:string("/Error/Code/text()", XmlDoc),
    [#xmlText{value=ErrorMessage}] = xmerl_xpath:string("/Error/Message/text()", XmlDoc),
    { s3error, ErrorCode, ErrorMessage }.


xmlToBuckets( {ok,_Headers,Body} ) ->
    {XmlDoc, _Rest} = xmerl_scan:string( Body ),
    TextNodes       = xmerl_xpath:string("//Bucket/Name/text()", XmlDoc),
    lists:map( fun (#xmlText{value=T}) -> T end, TextNodes).

