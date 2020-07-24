% Distributed chat rooms using a token ring
%
% Compile with : c("chat.erl").
% Examples :
%       chat:start(2,3).        -> creates 2 rooms and 3 clients/bots
%
% Authors : Johan Jobin, Julien Clement, University of Fribourg, Switzerland
% Version 1.0, 18.12.17


-module(chat).
-export([start/2, getTime/0, cr/4, cl/3, cl_deployment/1, accept/2, manualMaster/2, loop/5, flow/3, manualTokenHandler/2, reuseport/0]).

% binary : received packet delivered as a binary
% {packet, 0} : length of the packet's header
% {active, false} : use recv to retrieve the messages
% {reuseaddr, true} : allows to bind multiple sockets to a unique port/ip address
-define(TCP_OPTIONS, [{packet, 0}, {active, false}, {reuseaddr, true}, {exit_on_close, true}]).
-define(PORTNB, 8070).


% @spec start(NbRooms::integer(), NbClients::integer())
% function called by the user
% --> start(NbRooms, NbClients).
% ----------------------------------------------------------------------------------------------------
% Starts the deployment of the rooms
% ----------------------------------------------------------------------------------------------------
start(NbRooms, NbClients) ->
  reuseport(),
  Master = self(),
  {ok, [_|Ns]} = file:consult('enodes.conf'),
  [N|Ns2] = Ns,


  % spawn the first chat room, which will spawn the next one, and so on
  ArgsCR = [[],[], Master, []],
  Source = spawn(N, ?MODULE, cr, ArgsCR),
  Source ! {start_deploy, Ns2, NbRooms-1, ArgsCR, [Source]},

  % end of deployment of chat rooms
  receive
    {pidRooms, PIDs, NodesRemaining} -> start(NbClients, PIDs, NodesRemaining);                           % deployment succeeded -> deploy the bots

    {error, nodes, PIDRooms} ->                                                                           % deployment failed -> not enough nodes
      io:format("--- ERROR FROM Master(~w,~w) : not enough nodes available~n", [NbRooms, NbClients]),
      [ P ! {stop}  ||  P <- PIDRooms ]                                                                   % close the already existing rooms
  end.


% ----------------------------------------------------------------------------------------------------
% Starts the deployment of the bots
% ----------------------------------------------------------------------------------------------------
start(NbClients, PIDRooms, NodesRemaining) ->
  [N|Ns2] = NodesRemaining,
  ArgsCL = [self()],

  % spawn the first bot, which will spawn the next one, and so on
  Source = spawn(N, ?MODULE, cl_deployment, ArgsCL),
  Source ! {start_deploy, Ns2, NbClients-1, ArgsCL, [Source]},

  % end of deployment of the bots
  receive
    {end_deploy, PIDClients} ->
      [ P ! {activation}  ||  P <- PIDClients ],                                % clients leave the deployment phase
      ArgsMM = [?PORTNB, self()],
      spawn(?MODULE, manualMaster, ArgsMM),                                     % spawn manualMaster
      master(PIDRooms, PIDClients)                                              % server ready to be used
  end.



% ----------------------------------------------------------------------------------------------------
% Server in use
% ----------------------------------------------------------------------------------------------------
master(PIDRooms, PIDClients) ->

  receive

    % a bot requests the list of the rooms
    {getRooms, PID} ->
      PID ! {getRoomsAnswer, PIDRooms},
      master(PIDRooms, PIDClients);


    % first room attribution
    {chooseRoom, OldRoom, NewRoom, PID} when OldRoom =:= undef ->

      % log : a new bot enters the room
      P = io_lib:format("~p",[NewRoom]),
      FileName=string:concat("./ChatRoom", P),
      file:write_file(FileName, io_lib:format("~n~n------- ~w enters Room~n", [PID]), [append]),

      NewRoom ! {op, addMember, PID},
      master(PIDRooms, PIDClients);


    % room change, bot already in a room
    {chooseRoom, OldRoom, NewRoom, PID} when OldRoom =/= undef ->
      % log : bot leaves the old room
      P = io_lib:format("~p",[OldRoom]),
      FileName=string:concat("./ChatRoom", P),
      file:write_file(FileName, io_lib:format("~n~n------ ~w leaves Room ----- To Room ~w~n", [PID, NewRoom]), [append]),

      % log : bot enters the new room
      N = io_lib:format("~p",[NewRoom]),
      FileNameN=string:concat("./ChatRoom", N),
      file:write_file(FileNameN, io_lib:format("~n~n------ ~w enters Room ----- From Room ~w~n", [PID, OldRoom]), [append]),

      % remove bot from old room, add it to new room
      OldRoom ! {op, removeMember, PID},
      NewRoom ! {op, addMember, PID},
      master(PIDRooms, PIDClients);


    % client : disconnects
    {chooseRoom, quit, OldRoom, NewRoom, PID} when NewRoom =:= undef ->

      % if the client disconnects without beeing in a room
      case OldRoom of
        undef ->
          ok;

        _ ->
          % log : client disconnected
          P = io_lib:format("~p",[OldRoom]),
          FileName=string:concat("./ChatRoom", P),
          file:write_file(FileName, io_lib:format("~n~n------- ~w leaves Room~n", [PID]), [append]),

          OldRoom ! {op, removeMember, PID}
      end,
      master(PIDRooms, PIDClients);


    % human client : first room choice
    {chooseRoom, manual, OldRoom, NewRoom, PID} when OldRoom =:= undef ->
      NewRoom ! {op, addMemberManual, PID},
      master(PIDRooms, PIDClients);


    % human client : changes room
    {chooseRoom, manual, OldRoom, NewRoom, PID} when OldRoom =/= undef ->
      OldRoom ! {op, removeMemberManual, PID},
      NewRoom ! {op, addMemberManual, PID},
      master(PIDRooms, PIDClients);


    % human client : disconnects
    {chooseRoom, manual, quit, OldRoom, NewRoom, PID} when NewRoom =:= undef ->
      % if the client disconnects without beeing in a room
      case OldRoom of
        undef ->
          ok;

        _ ->
          OldRoom ! {op, removeMember, PID}
      end,
      master(PIDRooms, PIDClients);


    % master updates the log file of the chat room which received a message
    {msg, Content, Time, PID, PIDCR} ->

      % log example : {{2017,12,8},{17,31,11}}, <6397.47.0> : "Tom got a small piece of pie."
      P = io_lib:format("~p",[PIDCR]),
      FileName=string:concat("./ChatRoom", P),
      file:write_file(FileName, io_lib:format("~w, ~w : ~p~n", [Time, PID, Content]), [append]),

      master(PIDRooms, PIDClients)
  end.


% ----------------------------------------------------------------------------------------------------
% HUMAN CLIENT
% Server handling the manual client
% http://20bits.com/article/network-programming-in-erlang
% ----------------------------------------------------------------------------------------------------
manualMaster(Port, Master) ->
    {ok, LSocket} = gen_tcp:listen(Port, ?TCP_OPTIONS),
    accept(LSocket, Master).


% Sends the welcome message
% Spawns : loop, flow, manualTokenHandler
% Waits for the another human client to connect
accept(LSocket, Master) ->
  {ok, Socket} = gen_tcp:accept(LSocket),
  gen_tcp:send(Socket, "
  ██╗    ██╗███████╗██╗      ██████╗ ██████╗ ███╗   ███╗███████╗
  ██║    ██║██╔════╝██║     ██╔════╝██╔═══██╗████╗ ████║██╔════╝
  ██║ █╗ ██║█████╗  ██║     ██║     ██║   ██║██╔████╔██║█████╗
  ██║███╗██║██╔══╝  ██║     ██║     ██║   ██║██║╚██╔╝██║██╔══╝
  ╚███╔███╔╝███████╗███████╗╚██████╗╚██████╔╝██║ ╚═╝ ██║███████╗
  ╚══╝╚══╝ ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝

  Johan Jobin, Julien Clement, University of Fribourg, 2017.

  Commands :
      send a message -> S_yourMessage
      get the list of rooms -> G_
      choose a room -> C_roomNumber, where roomNumber = 1, 2, ...
      receive mode (stream of messages coming from the chat room) -> R_
      suspend the incoming stream of messages -> P_
      quit -> Q_

"),

  PIDFlow = spawn(fun() -> flow(Socket, "R", []) end),
  PIDManualTokenHandler = spawn(fun() -> manualTokenHandler([], undef) end),
  spawn(fun() -> loop(Socket, Master, undef, PIDFlow, PIDManualTokenHandler) end),
  accept(LSocket, Master).


% ----------------------------------------------------------------------------------------------------
% HUMAN CLIENT
% Handles all requests coming from a human client
% ----------------------------------------------------------------------------------------------------
loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler) ->
  case gen_tcp:recv(Socket, 0) of
    {ok, Dat} ->
      {Data,_} = lists:splitwith(fun(X) -> X =/= $\r end, Dat),
      case Data of
        [] ->
          loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler);

        _ -> ok
      end,

      [F,S|Rest] = Data,
      Sliced = [F]++[S],

      case Sliced of

        % change room
        "C_" ->
          {Int, _} = string:to_integer(Rest),
          Master ! {getRooms, self()},
          receive
            {getRoomsAnswer, PIDRooms} ->
              case ( (Int =< erlang:length(PIDRooms))
                and (Int > 0) ) of
                true ->
                  Master ! {chooseRoom, ChatRoom, lists:nth(Int, PIDRooms), PIDManualTokenHandler},
                  Master ! {chooseRoom, manual, ChatRoom, lists:nth(Int, PIDRooms), PIDFlow},
                  PIDManualTokenHandler ! {changeRoom, lists:nth(Int, PIDRooms)},
                  PIDFlow ! {changeRoom},

                  Msg = io_lib:format("Changement de salle\n", []),
                  gen_tcp:send(Socket, Msg),
                  loop(Socket, Master, lists:nth(Int,PIDRooms), PIDFlow, PIDManualTokenHandler);

                false ->
                  Rooms = lists:seq(1,erlang:length(PIDRooms)),
                  Msg = io_lib:format("Please choose a valid room : C_room~n~nRooms available : ~p~n~n", [Rooms]),
                  gen_tcp:send(Socket, Msg),
                  loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler)
              end
          end;


        % get the list of rooms
        "G_" ->
          Master ! {getRooms, self()},
          receive
            {getRoomsAnswer, PIDRooms} ->
              Rooms = lists:seq(1,erlang:length(PIDRooms)),
              Msg = io_lib:format("Rooms available : ~p~n~n", [Rooms]),
              gen_tcp:send(Socket, Msg),
              loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler)
          end;


        % send a message
        "S_" ->
          case (ChatRoom) of
              undef ->
                Master ! {getRooms, self()},
                receive
                  {getRoomsAnswer, PIDRooms} ->
                    Rooms = lists:seq(1,erlang:length(PIDRooms)),
                    Msg = io_lib:format("Please choose a room : C_room~n~nRooms available : ~p~n~n", [Rooms]),
                    gen_tcp:send(Socket, Msg),
                    loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler)
                end;

              _ ->
                PIDManualTokenHandler ! {msg, Rest},
                loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler)
          end;


        % receive mode : messages appear as soon as they're sent
        "R_" ->
          PIDFlow ! {mode, "R"},
          loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler);


        % pause mode : messages stored in a buffer. Allows the client to type
        % something without beeing interrupted by a new incoming message
        "P_" ->
          PIDFlow ! {mode, "P"},
          loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler);


        % disconnect
        "Q_" ->
          Master ! {chooseRoom, quit, ChatRoom, undef, self()},
          Master ! {chooseRoom, manual, quit, ChatRoom, undef, PIDFlow},
          PIDFlow ! {stop},
          PIDManualTokenHandler ! {stop},
          gen_tcp:close(Socket);


        % invalid request
        _ ->
          gen_tcp:send(Socket, Data),
          loop(Socket, Master, ChatRoom, PIDFlow, PIDManualTokenHandler)

      end
  end.


% ----------------------------------------------------------------------------------------------------
% HUMAN CLIENT
% Sends the messages : from the chat room to the human client
% ----------------------------------------------------------------------------------------------------
flow(Socket, Mode, Hist) ->
  receive
    % mode change : R receive, P pause
    {mode, M} ->
      flow(Socket, M, Hist);


    % room change : clear Hist
    {changeRoom} ->
      flow(Socket, Mode, []);


    % new message :
    % --> R -> send it to the client
    % --> P -> store it while in P mode, then send when in R mode
    {msg, Content, Time, PID} ->
      case Mode of
        "R" ->
          case Hist of
            [] ->
              Msg = io_lib:format("~w, ~w : ~p\n", [Time, PID, Content]),
              gen_tcp:send(Socket, Msg),
              flow(Socket, Mode, []);

            _ ->
              send(Socket, Hist),
              Msg = io_lib:format("~w, ~w : ~p\n", [Time, PID, Content]),
              gen_tcp:send(Socket, Msg),
              flow(Socket, Mode, [])
          end;

        "P" ->
          Msg = io_lib:format("~w, ~w : ~p\n", [Time, PID, Content]),
          flow(Socket, Mode, lists:append(Hist, [Msg]))
      end;


    {newMember, PID} ->
      case Mode of
        "R" ->
          case Hist of
            [] ->
              Msg = io_lib:format("-----> ~w enters\n", [PID]),
              gen_tcp:send(Socket, Msg),
              flow(Socket, Mode, []);

            _ ->
              send(Socket, Hist),
              Msg = io_lib:format("-----> ~w enters\n", [PID]),
              gen_tcp:send(Socket, Msg),
              flow(Socket, Mode, [])
          end;

        "P" ->
          Msg = io_lib:format("-----> ~w enters\n", [PID]),
          flow(Socket, Mode, lists:append(Hist, [Msg]))
      end;


    % stop
    {stop} -> ok

  end.


% ----------------------------------------------------------------------------------------------------
% HUMAN CLIENT
% Token management
% ----------------------------------------------------------------------------------------------------
manualTokenHandler(Hist, ChatRoom) ->
  receive

    % token received : send the messages that the human client wants to send
    {token, Token, PID} ->
      case Hist of
        [] ->
          PID ! {token, Token},
          manualTokenHandler(Hist, ChatRoom);

        _ ->
          PID ! {msg, Hist, self(), Token},
          manualTokenHandler([], ChatRoom)
      end;


    % client wants to send a message : store it in the Hist buffer, waiting for the token
    {msg, Content} ->
      manualTokenHandler(string:concat(Hist, Content), ChatRoom);


    % room change : clear the buffer
    {changeRoom, CR} ->
      manualTokenHandler([], CR);


    % stop
    {stop} -> ok

  end.




% ----------------------------------------------------------------------------------------------------
% Rooms : deployment or communication
% ----------------------------------------------------------------------------------------------------
cr(Members, Hist, Master, ManualMembers) ->
  receive

    %%%%%%%%%%%%%% deployment

    % standard deployment -> remote nodes available
    {start_deploy, NodesRemaining, NbRooms, Args, PIDRooms} when (NbRooms > 0) and (length(NodesRemaining) > 0) ->
      [N|Ns2] = NodesRemaining,
      PID = spawn(N, ?MODULE, cr, Args),
      PID ! {start_deploy, Ns2, NbRooms-1, Args, PIDRooms++[PID]},
      cr(Members, Hist, Master, ManualMembers);


    % end of deployment -> remote nodes still available for the bots (at least one)
    {start_deploy, NodesRemaining, NbRooms, _, PIDRooms} when (NbRooms =:= 0) and (length(NodesRemaining) > 0) ->
      Master ! {pidRooms, PIDRooms, NodesRemaining},
      cr(Members, Hist, Master, ManualMembers);


    % error : not enough nodes available to spawn the desired chat rooms on different remote nodes
    {start_deploy, NodesRemaining, _, _, PIDRooms} when (length(NodesRemaining) =:= 0) ->
      Master ! {error, nodes, PIDRooms},
      cr(Members, Hist, Master, ManualMembers);



    %%%%%%%%%%%%%% chat room working

    % add new member
    {op, addMember, Member} ->

      % send token to bot if it is the only one in the room
      case (erlang:length(Members) =:= 0) of
        true ->
          Member ! {token, 1, self()},
          cr(lists:append(Members, [Member]), Hist, Master, ManualMembers);

        false ->
          [ V ! {newMember, Member}  ||  V <- ManualMembers ],
          cr(lists:append(Members, [Member]), Hist, Master, ManualMembers)
      end;


    % new human client
    {op, addMemberManual, Member} ->
      cr(Members, Hist, Master, lists:append(ManualMembers, [Member]));


    % remove member
    {op, removeMember, Member} ->
      cr(Members -- [Member], Hist, Master, ManualMembers);


    {op, removeMemberManual, Member} ->
      cr(Members, Hist, Master, ManualMembers -- [Member]);
      % cr(Members, Hist, Master, []);


    % message received
    {msg, Content, PID, Token} ->

      % send the message to be added in the log file of the concerned room
      Master ! {msg, Content, getTime(), PID, self()},

      [ V ! {msg, Content, getTime(), PID}  ||  V <- ManualMembers ],

      % if the room is empty, do not send to token to anyone
      % otherwise, send it to the next member
      case(erlang:length(Members) =:= 0) of
        true ->
          cr(Members,[[Hist++[getTime()]]++[PID]++[Content]], Master, ManualMembers);

        false ->
          % if there does not exist a next member -> end of the list Members, send token to the first member
          % otherwise, send the token the the next member
          case (Token+1 > erlang:length(Members)) of
            true ->
              lists:nth(1, Members) ! {token, 1, self()};

            false ->
              lists:nth(Token+1, Members) ! {token, Token+1, self()}
          end,
          cr(Members,[[Hist++[getTime()]]++[PID]++[Content]], Master, ManualMembers)
        end;


    % bot does not want to send a message
    % happens when a bot wants to leave the room and go into another one
    {token, Token} ->

      % if the room is empty, do not send to token to anyone
      % otherwise, send it to the next member
      case (erlang:length(Members) =:= 0) of
        true ->
          cr(Members, Hist, Master, ManualMembers);

        false ->
          % if there does not exist a next member -> end of the list Members, send token to the first member
          % otherwise, send the token the the next member
          case (Token+1 > erlang:length(Members)) of
            true ->
              lists:nth(1, Members) ! {token, 1, self()};

            false ->
              lists:nth(Token+1, Members) ! {token, Token+1, self()}
          end,
          cr(Members, Hist, Master, ManualMembers)
      end
  end.



% ----------------------------------------------------------------------------------------------------
% Bots : deployment
% ----------------------------------------------------------------------------------------------------
cl_deployment(Master) ->

  receive
    % deployment

    % standard case -> remote nodes still available, spawn bots onto them
    {start_deploy, NodesRemaining, NbClients, Args, PIDClients} when (NbClients > 0) and (length(NodesRemaining) > 0) ->
      [N|Ns2] = NodesRemaining,
      PID = spawn(N, ?MODULE, cl_deployment, Args),
      PID ! {start_deploy, Ns2, NbClients-1, Args, PIDClients++[PID]},
      cl_deployment(Master);


    % only one remote node available -> spawn all the remaining bots onto the same remote node
    {start_deploy, NodesRemaining, NbClients, Args, PIDClients} when (NbClients > 0) and (length(NodesRemaining) =:= 0) ->
      Vs = lists:seq(0,NbClients-1),
      PIDs = [spawn(?MODULE, cl_deployment, Args) || _ <- Vs],
      Master ! {end_deploy, PIDClients++PIDs},
      cl_deployment(Master);


    % end of deployment
    {start_deploy, _, NbClients, _, PIDClients} when (NbClients =:= 0) ->
      Master ! {end_deploy, PIDClients},
      cl_deployment(Master);


    % from master -> deployment ended -> bots go to the "working" phase
    {activation} ->
      {ok, Sentences} = file:consult('phrases.txt'),
      cl(Master, undef, Sentences)

  end.


% ----------------------------------------------------------------------------------------------------
% Bots working
% ----------------------------------------------------------------------------------------------------

% force bot to choose a room -> when they do not have one yet
cl(Master, ChatRoom, Sentences) when ChatRoom =:= undef ->

  % request the list of rooms, choose one randomly, notify the master
  Master ! {getRooms, self()},
  receive
    {getRoomsAnswer, PIDRooms} ->
      Room = lists:nth(randomIndex(erlang:length(PIDRooms)), PIDRooms),

      Master ! {chooseRoom, undef, Room, self()},
      cl(Master, Room, Sentences)
  end;


% standard behaviour
cl(Master, ChatRoom, Sentences) ->
  receive

    % when the bot receives the token, it can either send a message (90% chance) or leave the room (10% chance)
    {token, Token, PID} ->

      timer:sleep(2000 + randomIndex(5000)),

      case (randomIndex(100) =< 90) of
        % send a message
        true ->
          % security : when changing room
          case (PID =/= ChatRoom) of
            true ->
              PID ! {token, Token-1},
              cl(Master, ChatRoom, Sentences);

            false ->
              PID ! {msg, lists:nth(randomIndex(erlang:length(Sentences)), Sentences), self(), Token},
              % PID ! {msg, io_lib:format("~w",[Token]), self(), Token},
              cl(Master, ChatRoom, Sentences)
          end;

        % change room -> has to send the token back to the chat room
        false ->
          Master ! {getRooms, self()},
          receive
            {getRoomsAnswer, PIDRooms} ->
              case (erlang:length(PIDRooms) =:= 1) of
                true ->
                  PID ! {token, Token},
                  cl(Master, ChatRoom, Sentences);

                false ->
                  NewRoom = changeRoom(ChatRoom, PIDRooms),
                  Master ! {chooseRoom, ChatRoom, NewRoom, self()},
                  timer:sleep(100),
                  PID ! {token, Token-1},
                  cl(Master, NewRoom, Sentences)
              end
          end
        end
      end.


% ----------------------------------------------------------------------------------------------------
% Helper functions
% ----------------------------------------------------------------------------------------------------

% returns a tuple {{Year,Month,Day},{H,M,S}} based on the current time
getTime() ->
  calendar:now_to_local_time(os:timestamp()).


% returns a random number between 1 and length included
% random:uniform() did not work :
%   -> when called twice in the same process -> returns two different numbers
%   -> when called in two or more parallel processes -> returns the same number
% Index has to be >= 1 (in order to use it with lists:nth())
randomIndex(Length) ->
  {A,B,C} = now(),
  random:seed(A,B,C),
  Index = (A+B+C) rem (Length+1),
  case (Index =:= 0) of
    true ->
      1;

    false ->
      Index
  end.


% returns a new room that is different from the one in which the bot was
changeRoom(OldRoom, PIDRooms) ->
  lists:nth(randomIndex(erlang:length(PIDRooms -- [OldRoom])), PIDRooms -- [OldRoom]).


% sends all messages contained in the Hist buffer
send(Socket, Hist) ->
  case Hist of
    [] ->
      ok;

    _ ->
      [H|T] = Hist,
      gen_tcp:send(Socket, H),
      send(Socket, T)
  end.


% make the port leave the listening state in order to reuse the same port
reuseport()->
  Port = io_lib:format("~w",[?PORTNB]),
  Cmd = string:concat("fuser ", string:concat(Port, "/tcp")),
  % io:format("~s~n", [Cmd]).
  Fuser = os:cmd(Cmd),
  case Fuser of
    [] -> ok;

    _ ->
      Nb = g(Fuser, 0),
      Kill = string:concat("kill -9 ", Nb),
      os:cmd(Kill)
  end.

% reuseport() helper
g(Str,It) ->
  case (It < 16) of
    true ->
      [_|T] = Str,
      g(T,It+1);

    false ->
      [X||X<-Str,X=/=$\n]
  end.
