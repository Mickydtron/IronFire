module IronFire.View exposing (..)

import Html exposing (..)
import Html.Events exposing (onInput, onClick, on, keyCode, onFocus, onBlur)
import Html.Attributes exposing (..)
import Svg
import Svg.Attributes as SA
import IronFire.Model exposing (..)
import Json.Decode as JD
import Color.Interpolate as Interpolate exposing (Space(..))
import Color.Convert as CC
import Color exposing (rgb)
import Time exposing (Time)


view : Model -> Html Msg
view model =
    let
        frozen =
            model.status == Frozen

        selectedId =
            Maybe.withDefault -1 model.selectedId

        viewFilter =
            case model.viewFilter of
                ViewAll ->
                    always True

                ViewAlive ->
                    isAlive

                ViewFinished ->
                    .status >> (==) Finished

                ViewDead ->
                    .status >> (==) Dead

        saveAllDisabled =
            not <| List.any (.saveStatus >> (/=) Saved) model.todos

        coldLength =
            (toFloat model.settings.coldLength) * (toTime model.settings.coldLengthUnit)
    in
        div [ class "container" ]
            [ table [ class "table table-condensced" ]
                [ tr []
                    [ displayViewFilterButtons model.viewFilter
                    , button [ type_ "button", class "btn btn-primary pull-right", onClick SaveAllUnsaved, disabled saveAllDisabled ] [ text "Save All" ]
                    , button [ type_ "button", class "btn pull-right", onClick TryReconnect, disabled (model.phxStatus == Joined) ] [ text "Reconnect" ]
                    ]
                ]
            , table [ class "table table-condensced" ]
                [ thead []
                    [ tr []
                        [ th [] [ text "Task" ]
                        , th [] [ text "Status" ]
                        , th [] []
                        , th [] []
                        , th [] []
                        ]
                    ]
                , tbody []
                    ((List.concatMap (displayTodo model.currentTime coldLength frozen selectedId) <| List.filter viewFilter <| List.sortBy .lastWorked model.todos)
                        ++ [ displayInputRow model.inputText ]
                    )
                ]
            , displaySettingsArea model.settings
            ]


displayViewFilterButtons : ViewFilter -> Html Msg
displayViewFilterButtons filter =
    let
        getClass =
            (\c ->
                if c == filter then
                    "btn btn-info"
                else
                    "btn"
            )

        displayViewButton view label =
            button [ type_ "button", class <| getClass view, onClick <| SetViewFilter view ] [ text label ]
    in
        div [ class "btn-group" ]
            [ displayViewButton ViewAll "All"
            , displayViewButton ViewAlive "Active"
            , displayViewButton ViewFinished "Finished"
            , displayViewButton ViewDead "Dead"
            ]


displayTodo : Time -> Time -> Bool -> Int -> Todo -> List (Html Msg)
displayTodo currentTime coldLength frozen selectedId todo =
    let
        isSelected =
            todo.elmId == selectedId

        rowClass =
            if isSelected then
                "info"
            else if (frozen && todo.status == Cold) then
                "active"
            else
                ""

        rowAttributes =
            [ class rowClass ]
                ++ if isSelected then
                    []
                   else
                    [ onClick <| SelectTodo todo.elmId ]

        tdTodoTextElement =
            case ( todo.input, isAlive todo, isSelected ) of
                ( Just inputText, True, _ ) ->
                    td []
                        [ input
                            [ type_ "text"
                            , class "form-control"
                            , id <| "todo-input-" ++ toString todo.elmId
                            , onInput <| SetTodoInput todo.elmId
                            , placeholder todo.text
                            , value inputText
                            , onEnter NoOp <| FinishTodoInput todo.elmId
                            , onEsc NoOp <| CancelTodoInput todo.elmId
                            ]
                            []
                        ]

                ( Nothing, True, True ) ->
                    td [ onClick <| SetTodoInput todo.elmId "" ] [ text todo.text ]

                ( _, _, _ ) ->
                    td [] [ text todo.text ]

        hotColor =
            rgb 255 255 0

        warmColor =
            rgb 255 224 0

        coolColor =
            rgb 255 32 0

        coldColor =
            rgb 128 128 128

        startTime =
            Time.inMilliseconds todo.lastWorked

        timeAdjustmentFromWarmMethod =
            case todo.warmMethod of
                Work ->
                    1.0

                Renew ->
                    0.5

        warmTime =
            startTime + ((Time.inMilliseconds coldLength) * timeAdjustmentFromWarmMethod * 1 / 3)

        coolTime =
            startTime + ((Time.inMilliseconds coldLength) * timeAdjustmentFromWarmMethod * 2 / 3)

        coldTime =
            startTime + ((Time.inMilliseconds coldLength) * timeAdjustmentFromWarmMethod)

        ironColor =
            case todo.status of
                Hot ->
                    Interpolate.interpolate LAB hotColor warmColor (normalizeTime startTime warmTime currentTime)
                        |> CC.colorToHex

                Warm ->
                    Interpolate.interpolate LAB warmColor coolColor (normalizeTime warmTime coolTime currentTime)
                        |> CC.colorToHex

                Cool ->
                    Interpolate.interpolate LAB coolColor coldColor (normalizeTime coolTime coldTime currentTime)
                        |> CC.colorToHex

                Cold ->
                    coldColor |> CC.colorToHex

                Finished ->
                    "black"

                Dead ->
                    "black"

        tempElement =
            anvil ironColor

        extraButtons =
            if frozen && todo.status == Cold then
                [ button [ type_ "button", class "btn btn-warning", onClick <| RenewTodo todo.elmId ] [ text "Renew" ]
                ]
            else
                []

        buttons =
            case ( todo.input, (isSelected && (isAlive todo) && (not frozen)) || (frozen && todo.status == Cold) ) of
                ( Nothing, True ) ->
                    div [ class "btn-group" ]
                        ([ button [ type_ "button", class "btn btn-info", onClick <| DoWorkOnTodo todo.elmId ] [ text "I Worked On This" ]
                         , button [ type_ "button", class "btn btn-success", onClick <| FinishTodo todo.elmId ] [ text "Finish" ]
                         ]
                            ++ extraButtons
                            ++ [ button [ type_ "button", class "btn btn-danger", onClick <| KillTodo todo.elmId ] [ text "Kill" ]
                               ]
                        )

                ( Just _, _ ) ->
                    div [ class "btn-group" ]
                        [ button [ type_ "button", class "btn btn-info", onClick <| FinishTodoInput todo.elmId ] [ text "Update" ]
                        , button [ type_ "button", class "btn btn-warning", onClick <| CancelTodoInput todo.elmId ] [ text "Cancel" ]
                        ]

                ( _, _ ) ->
                    div [] []

        saveText =
            case todo.saveStatus of
                Saved ->
                    ""

                Modified ->
                    "*"

                Unsaved ->
                    "!"

        notesrow =
            if isSelected then
                [ tr [ class "info" ]
                    [ td [ colspan 5 ]
                        [ textarea
                            [ class "form-control"
                            , id <| "todo-notes-" ++ toString todo.elmId
                            , placeholder "Notes"
                            , value todo.notes
                            , maxlength 255
                            , onInput <| SetTodoNotes todo.elmId
                            , onEsc NoOp <| BlurNotes todo.elmId
                            , onFocus <| SetEditingNotes True
                            , onBlur <| SetEditingNotes False
                            ]
                            []
                        ]
                    ]
                ]
            else
                []
    in
        [ tr rowAttributes
            [ tdTodoTextElement
            , td [] [ tempElement ]
            , td [] [ span [ class "badge" ] [ text <| toString todo.timesRenewed ] ]
            , td [] [ buttons ]
            , td [] [ text saveText ]
            ]
        ]
            ++ notesrow


displayInputRow : String -> Html Msg
displayInputRow inputText =
    tr []
        [ td []
            [ div [ class "form-group" ]
                [ input [ type_ "text", class "form-control", id "task-input", onInput SetInput, placeholder "New Todo", value inputText, onEnter NoOp AddTodo, onFocus <| UnselectTodo ] []
                ]
            ]
        , td [] []
        , td [] []
        , td []
            [ button [ type_ "button", class "btn btn-primary", onClick AddTodo ] [ text "Add Todo" ]
            ]
        , td [] []
        ]


onEnter : msg -> msg -> Attribute msg
onEnter fail success =
    let
        tagger code =
            if code == 13 then
                success
            else
                fail
    in
        on "keypress" (JD.map tagger keyCode)


onKeyup : Int -> msg -> msg -> Attribute msg
onKeyup code fail success =
    let
        tagger code_ =
            if code_ == code then
                success
            else
                fail
    in
        on "keyup" (JD.map tagger keyCode)


onEsc : msg -> msg -> Attribute msg
onEsc =
    onKeyup 27


displaySettingsArea : AppSettings -> Html Msg
displaySettingsArea settings =
    let
        body =
            if settings.show then
                displaySettingsPanelBody settings
            else
                div [] []
    in
        div [ class "panel panel-default" ]
            [ div [ class "panel-heading", onClick ToggleSettings ]
                [ h3 [ class "panel-title" ] [ text "Settings" ] ]
            , body
            ]


displaySettingsPanelBody : AppSettings -> Html Msg
displaySettingsPanelBody settings =
    div [ class "panel-body" ]
        [ Html.form [ class "form-horizontal" ]
            [ div [ class "form-group" ]
                [ label [ for "freezeThreshold", class "col-sm-3 control-label" ] [ text "Freeze Threshold" ]
                , div [ class "col-sm-9" ]
                    [ input [ type_ "number", class "form-control", id "freezeThreshold", onInput SetThreshold, value <| toString settings.freezeThreshold ] [] ]
                ]
            , div [ class "form-group" ]
                [ label [ for "intervalNumber", class "col-sm-3 control-label" ] [ text "Interval" ]
                , div [ class "col-sm-6" ]
                    [ input [ type_ "number", class "form-control", id "intervalNumber", onInput SetColdCheckInterval, value <| toString settings.coldCheckInterval ] [] ]
                , div [ class "col-sm-3" ]
                    [ label [ for "intervalUnit", class "sr-only" ] [ text "Inverval Unit" ]
                    , select [ class "form-control", onInput SetColdCheckIntervalUnit, id "intervalUnit" ]
                        [ option [ selected <| settings.coldCheckIntervalUnit == Seconds ] [ text <| toString Seconds ]
                        , option [ selected <| settings.coldCheckIntervalUnit == Minutes ] [ text <| toString Minutes ]
                        ]
                    ]
                ]
            , div [ class "form-group" ]
                [ label [ for "coldLength", class "col-sm-3 control-label" ] [ text "Time Before Cold" ]
                , div [ class "col-sm-6" ]
                    [ input [ type_ "number", class "form-control", id "coldLength", onInput SetColdLength, value <| toString settings.coldLength ] [] ]
                , div [ class "col-sm-3" ]
                    [ label [ for "coldLengthUnit", class "sr-only" ] [ text "Cold Length Unit" ]
                    , select [ class "form-control", onInput SetColdLengthUnit, id "coldLengthUnit" ]
                        [ option [ selected <| settings.coldLengthUnit == Seconds ] [ text <| toString Seconds ]
                        , option [ selected <| settings.coldLengthUnit == Minutes ] [ text <| toString Minutes ]
                        , option [ selected <| settings.coldLengthUnit == Hours ] [ text <| toString Hours ]
                        , option [ selected <| settings.coldLengthUnit == Days ] [ text <| toString Days ]
                        ]
                    ]
                ]
            ]
        , button [ type_ "button", class "btn btn-danger", onClick ClearLocalTodos ] [ text "Clear Local Todos" ]
        ]


anvil : String -> Html Msg
anvil color =
    Svg.svg [ SA.width "40", SA.height "20", SA.viewBox "0 0 100 50" ]
        [ Svg.path [ SA.d "M25 2 V0 H100 V5 C 75 5, 65 15, 65 25 C 65 30, 70 35, 75 35 V50 H25 V35 C 30 35, 35 30, 35 25 S 30 15, 25 15 S 0 12, 0 2 Z", SA.fill color ] []
        ]


normalizeTime : Float -> Float -> Float -> Float
normalizeTime start end point =
    (point - start) / (end - start)
