port module IronFire.Update exposing (..)

import IronFire.Model exposing (..)
import IronFire.Interop exposing (..)
import Time exposing (..)
import String exposing (toInt)
import Task exposing (perform)
import Phoenix.Socket
import Phoenix.Push


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            model ! []

        AddTodo ->
            case String.trim model.inputText of
                "" ->
                    ( model, Cmd.none )

                _ ->
                    { model
                        | todos = (newTodo model.nextId model.inputText) :: model.todos
                        , inputText = ""
                        , nextId = model.nextId + 1
                    }
                        ! [ updateTodoTimeAndSave model.nextId, focus "#task-input" ]

        SetInput text ->
            { model | inputText = text } ! []

        DoWorkOnTodo id ->
            ( updateSpecificTodo model id (\t -> { t | status = Hot }), updateTodoTimeAndSave id )

        FinishTodo id ->
            ( updateSpecificTodo model id (\t -> { t | status = Finished }), Cmd.none )
                |> withSaveTodosWhere (.elmId >> (==) id)

        KillTodo id ->
            ( updateSpecificTodo model id (\t -> { t | status = Dead }), Cmd.none )
                |> withSaveTodosWhere (.elmId >> (==) id)

        RenewTodo id ->
            ( updateSpecificTodo model id (\t -> { t | status = Hot, timesRenewed = t.timesRenewed + 1 }), updateTodoTimeAndSave id )

        SetTodoInput id input ->
            ( updateSpecificTodo model id (\t -> { t | input = Just input }), focus <| "#todo-input-" ++ toString id )

        CancelTodoInput id ->
            ( updateSpecificTodo model id (\t -> { t | input = Nothing }), Cmd.none )

        FinishTodoInput id ->
            let
                getNewText oldText input =
                    case Maybe.map String.trim input of
                        Nothing ->
                            oldText

                        Just "" ->
                            oldText

                        Just str ->
                            str
            in
                ( updateSpecificTodo model id (\t -> { t | input = Nothing, text = getNewText t.text t.input }), Cmd.none )
                    |> withSaveTodosWhere (.elmId >> (==) id)

        CheckForColdTodos time ->
            let
                coldLength =
                    (toFloat model.settings.coldLength) * (toTime model.settings.coldLengthUnit)

                newTodos =
                    List.map
                        (\t ->
                            if isAlive t then
                                if (time - t.lastTouched > coldLength) then
                                    { t | status = Cold }
                                else if (time - t.lastTouched > coldLength * (2 / 3)) then
                                    { t | status = Cool }
                                else if (time - t.lastTouched > coldLength * (1 / 3)) then
                                    { t | status = Warm }
                                else
                                    { t | status = Hot }
                            else
                                t
                        )
                        model.todos

                newStatus =
                    if model.status == Frozen || (List.length <| List.filter (.status >> (==) Cold) newTodos) >= model.settings.freezeThreshold then
                        Frozen
                    else
                        Normal
            in
                { model | todos = newTodos, status = newStatus } ! []

        UpdateTodoTimeAndSave id time ->
            ( updateSpecificTodo model id (\t -> { t | lastTouched = time }), Cmd.none )
                |> withSaveTodosWhere (.elmId >> (==) id)

        SetViewFilter newFilter ->
            { model | viewFilter = newFilter } ! []

        ToggleSettings ->
            let
                update settings =
                    { settings | show = not settings.show }
            in
                { model | settings = update model.settings } ! []

        SetThreshold text ->
            let
                settingsUpdater =
                    case toPositiveNumber text of
                        Ok num ->
                            (\s -> { s | freezeThreshold = num })

                        Err _ ->
                            Basics.identity
            in
                updateSettings { model | status = Normal } settingsUpdater

        SetColdCheckInterval text ->
            let
                settingsUpdater =
                    case toPositiveNumber text of
                        Ok num ->
                            (\s -> { s | coldCheckInterval = num })

                        Err _ ->
                            Basics.identity
            in
                updateSettings { model | status = Normal } settingsUpdater

        SetColdCheckIntervalUnit text ->
            updateSettings { model | status = Normal } (\s -> { s | coldCheckIntervalUnit = getTimeIntervalFromText text })

        SetColdLength text ->
            let
                settingsUpdater =
                    case toPositiveNumber text of
                        Ok num ->
                            (\s -> { s | coldLength = num })

                        Err _ ->
                            Basics.identity
            in
                updateSettings { model | status = Normal } settingsUpdater

        SetColdLengthUnit text ->
            updateSettings { model | status = Normal } (\s -> { s | coldLengthUnit = getTimeIntervalFromText text })

        RxTodosLocal value ->
            let
                newTodos =
                    case decodeTodos value of
                        Ok todos ->
                            todos

                        Err err ->
                            []

                highestId =
                    Maybe.withDefault 0 <| List.maximum <| List.map .elmId newTodos
            in
                { model | todos = newTodos ++ model.todos, nextId = max (highestId + 1) model.nextId } ! []

        RxTodoPhx value ->
            let
                updateModel m =
                    case decodeTodo value of
                        Ok todo ->
                            case List.filter (.phxId >> (==) todo.phxId) m.todos of
                                [] ->
                                    { m | todos = { todo | elmId = model.nextId } :: m.todos, nextId = m.nextId + 1 }

                                _ ->
                                    { m
                                        | todos =
                                            List.map
                                                (\t ->
                                                    if t.phxId == todo.phxId then
                                                        { todo | elmId = t.elmId }
                                                    else
                                                        t
                                                )
                                                m.todos
                                    }

                        Err err ->
                            Debug.log err m

                model' =
                    updateModel model
            in
                model' ! [ saveTodosLocal <| encodeLocalTodos model.userid model'.todos ]

        RxSettings value ->
            let
                settings' =
                    case decodeAppSettings value of
                        Ok settings ->
                            { settings | show = model.settings.show }

                        Err err ->
                            model.settings
            in
                { model | settings = settings' } ! []

        AckTodoPhx value ->
            let
                updateTodo =
                    case decodeAck value of
                        Ok ( phxId', elmId' ) ->
                            (\todo ->
                                if todo.elmId == elmId' then
                                    { todo | phxId = Just phxId' }
                                else
                                    todo
                            )

                        Err err ->
                            identity

                newTodos =
                    List.map updateTodo model.todos
            in
                { model | todos = newTodos }
                    ! [ saveTodosLocal <| encodeLocalTodos model.userid newTodos ]

        PhoenixMsg msg ->
            let
                ( phxSocket', phxCmd ) =
                    Phoenix.Socket.update msg model.phxSocket
            in
                { model | phxSocket = phxSocket' } ! [ Cmd.map PhoenixMsg phxCmd ]

        SaveAllUnsaved ->
            ( model, Cmd.none ) |> withSaveTodosWhere (.phxId >> (==) Nothing)



-- UPDATE HELPERS


checkUnfreeze : Model -> Model
checkUnfreeze model =
    if model.status == Frozen && List.all (.status >> (/=) Cold) model.todos then
        { model | status = Normal }
    else
        model


toPositiveNumber : String -> Result String Int
toPositiveNumber text =
    case toInt text of
        Ok num ->
            if num > 0 then
                Ok num
            else
                Err "Number is negative or zero"

        Err err ->
            Err err


getTimeIntervalFromText : String -> TimeInterval
getTimeIntervalFromText text =
    case text of
        "Seconds" ->
            Seconds

        "Minutes" ->
            Minutes

        "Hours" ->
            Hours

        "Days" ->
            Days

        _ ->
            Debug.crash "Tried to convert an invalid string into a TimeInterval"


updateSpecificTodo : Model -> Int -> (Todo -> Todo) -> Model
updateSpecificTodo model id updateTodo =
    let
        newTodos =
            List.map
                (\t ->
                    if t.elmId == id then
                        updateTodo t
                    else
                        t
                )
                model.todos
    in
        checkUnfreeze { model | todos = newTodos }


withSaveTodosWhere : (Todo -> Bool) -> ( Model, Cmd Msg ) -> ( Model, Cmd Msg )
withSaveTodosWhere gate ( model, cmdMsg ) =
    let
        reducer : Todo -> ( Phoenix.Socket.Socket Msg, Cmd Msg ) -> ( Phoenix.Socket.Socket Msg, Cmd Msg )
        reducer todo ( socket, cmd ) =
            let
                push' =
                    Phoenix.Push.init "set_todo" ("user:" ++ model.userid)
                        |> Phoenix.Push.withPayload (jsonTodo todo)

                ( newSocket, newCmd ) =
                    Phoenix.Socket.push push' socket
            in
                ( newSocket, Cmd.batch [ Cmd.map PhoenixMsg newCmd, cmd ] )

        ( phxSocket', cmd' ) =
            List.foldl reducer ( model.phxSocket, Cmd.none ) (List.filter gate model.todos)
    in
        { model | phxSocket = phxSocket' } ! [ cmdMsg, cmd', saveTodosLocal <| encodeLocalTodos model.userid model.todos ]


updateSettings : Model -> (AppSettings -> AppSettings) -> ( Model, Cmd Msg )
updateSettings model update =
    let
        newSettings =
            update model.settings

        push' =
            Phoenix.Push.init "set_settings" ("user:" ++ model.userid)
                |> Phoenix.Push.withPayload (jsonSettings newSettings)

        ( phxSocket', phxCmd ) =
            Phoenix.Socket.push push' model.phxSocket
    in
        { model
            | settings = newSettings
            , phxSocket = phxSocket'
        }
            ! [ checkForFreezeNow
              , saveSettingsLocal <| encodeLocalSettings model.userid newSettings
              , Cmd.map PhoenixMsg phxCmd
              ]



-- COMMANDS


port focus : String -> Cmd msg


port connectLocal : String -> Cmd msg


port saveTodosLocal : String -> Cmd msg


port saveSettingsLocal : String -> Cmd msg


updateTodoTimeAndSave : Int -> Cmd Msg
updateTodoTimeAndSave id =
    Task.perform (\_ -> Debug.crash "Time Fetch Failed") (UpdateTodoTimeAndSave id) Time.now


checkForFreezeNow : Cmd Msg
checkForFreezeNow =
    Task.perform (\_ -> Debug.crash "Time Fetch Failed") CheckForColdTodos Time.now



-- SUBSCRIPTIONS


port rxTodos : (Value -> msg) -> Sub msg


port rxSettings : (Value -> msg) -> Sub msg


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        interval =
            (toFloat model.settings.coldCheckInterval) * (toTime model.settings.coldCheckIntervalUnit)
    in
        Sub.batch
            [ Time.every interval CheckForColdTodos
            , rxTodos RxTodosLocal
            , rxSettings RxSettings
            , Phoenix.Socket.listen model.phxSocket PhoenixMsg
            ]
