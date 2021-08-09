defmodule Membrane.WebRTC.EndpointBin do
  @moduledoc """
  Module responsible for interacting with a WebRTC peer.

  To send or receive tracks from a WebRTC peer, specify them with
  `:inbound_tracks` and `:outbound_tracks` options, and link corresponding
  `:input` and `:output` pads with ids matching the declared tracks' ids.

  The tracks can be manipulated by sending `t:track_message/0`.

  To initiate or modify the connection, the bin sends and expects to receive
  `t:signal_message/0`.
  """
  use Membrane.Bin
  use Bunch

  alias ExSDP.Media
  alias Membrane.WebRTC.{SDP, Track}

  @type signal_message ::
          {:signal, {:sdp_offer | :sdp_answer, String.t()} | {:candidate, String.t()}}

  @type track_message :: alter_tracks_message() | enable_track_message() | disable_track_message()

  @typedoc """
  Message that adds or removes tracks.
  """
  @type alter_tracks_message :: {:add_tracks, [Track.t()]} | {:remove_tracks, [Track.id()]}

  @typedoc """
  Message that enables track.
  """
  @type enable_track_message :: {:disable_track, Track.id()}

  @typedoc """
  Message that disables track.
  """
  @type disable_track_message :: {:disable_track, Track.id()}

  def_options inbound_tracks: [
                spec: [Membrane.WebRTC.Track.t()],
                default: [],
                description: "List of initial inbound tracks"
              ],
              outbound_tracks: [
                spec: [Membrane.WebRTC.Track.t()],
                default: [],
                description: "List of initial outbound tracks"
              ],
              stun_servers: [
                type: :list,
                spec: [ExLibnice.stun_server()],
                default: [],
                description: "List of stun servers"
              ],
              turn_servers: [
                type: :list,
                spec: [ExLibnice.relay_info()],
                default: [],
                description: "List of turn servers"
              ],
              port_range: [
                spec: Range.t(),
                default: 0..0,
                description: "Port range to be used by `Membrane.ICE.Bin`"
              ],
              handshake_opts: [
                type: :list,
                spec: Keyword.t(),
                default: [],
                description: """
                Keyword list with options for handshake module. For more information please
                refer to `Membrane.ICE.Bin`
                """
              ],
              video_codecs: [
                type: :list,
                spec: [ExSDP.Attribute.t()],
                default: [],
                description: "Video codecs that will be passed for SDP offer generation"
              ],
              audio_codecs: [
                type: :list,
                spec: [ExSDP.Attribute.t()],
                default: [],
                description: "Audio codecs that will be passed for SDP offer generation"
              ],
              use_default_codecs: [
                spec: [:audio | :video],
                default: [:audio, :video],
                description:
                  "Defines whether to use default codecs or not. Default codecs are those required by WebRTC standard - OPUS, VP8 and H264"
              ],
              log_metadata: [
                spec: :list,
                spec: Keyword.t(),
                default: [],
                description: "Logger metadata used for endpoint bin and all its descendants"
              ]

  def_input_pad :input,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      encoding: [
        spec: :OPUS | :H264,
        description: "Track encoding"
      ],
      track_enabled: [
        spec: boolean(),
        default: true,
        description: "Enable or disable track"
      ]
    ]

  def_output_pad :output,
    demand_unit: :buffers,
    caps: :any,
    availability: :on_request,
    options: [
      track_enabled: [
        spec: boolean(),
        default: true,
        description: "Enable or disable track"
      ],
      extensions: [
        spec: [Membrane.RTP.SessionBin.extension_t()],
        default: [],
        description: "List of tuples representing rtp extensions"
      ]
    ]

  @impl true
  def handle_init(opts) do
    children = %{
      ice: %Membrane.ICE.Bin{
        stun_servers: opts.stun_servers,
        turn_servers: opts.turn_servers,
        port_range: opts.port_range,
        controlling_mode: false,
        handshake_module: Membrane.DTLS.Handshake,
        handshake_opts: opts.handshake_opts
      },
      rtp: %Membrane.RTP.SessionBin{secure?: true},
      ice_funnel: Membrane.Funnel
    }

    rtp_input_ref = make_ref()

    links = [
      link(:rtp)
      |> via_out(Pad.ref(:rtcp_output, rtp_input_ref))
      |> to(:ice_funnel),
      link(:ice)
      |> via_out(Pad.ref(:output, 1))
      |> via_in(Pad.ref(:rtp_input, rtp_input_ref))
      |> to(:rtp),
      link(:ice_funnel)
      |> via_out(:output)
      |> via_in(Pad.ref(:input, 1))
      |> to(:ice)
    ]

    spec = %ParentSpec{
      children: children,
      links: links
    }

    state =
      %{
        inbound_tracks: %{},
        outbound_tracks: %{},
        audio_codecs: opts.audio_codecs,
        video_codecs: opts.video_codecs,
        use_default_codecs: opts.use_default_codecs,
        candidates: [],
        candidate_gathering_state: nil,
        dtls_fingerprint: nil,
        ssrc_to_mid: %{},
        track_id_to_mapping: %{}
      }
      |> add_tracks(:inbound_tracks, opts.inbound_tracks)
      |> add_tracks(:outbound_tracks, opts.outbound_tracks)

    {{:ok, spec: spec, log_metadata: opts.log_metadata}, state}
  end

  defp hex_dump(digest_str) do
    digest_str
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>))
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, track_id) = pad, ctx, state) do
    %{encoding: encoding} = ctx.options
    %Track{ssrc: ssrc} = Map.fetch!(state.outbound_tracks, track_id)
    %{track_enabled: track_enabled} = ctx.pads[pad].options

    mapping = state.track_id_to_mapping[track_id]

    encoding_specific_links =
      case encoding do
        :H264 -> &to(&1, {:h264_parser, ssrc}, %Membrane.H264.FFmpeg.Parser{alignment: :nal})
        _other -> & &1
      end

    links = [
      link_bin_input(pad)
      |> pipe_fun(encoding_specific_links)
      |> to({:track_filter, track_id}, %Membrane.WebRTC.TrackFilter{enabled: track_enabled})
      |> via_in(Pad.ref(:input, ssrc))
      |> to(:rtp)
      |> via_out(Pad.ref(:rtp_output, ssrc),
        options: [
          encoding: encoding,
          clock_rate: mapping.clock_rate,
          payload_type: mapping.payload_type
        ]
      )
      |> to(:ice_funnel)
    ]

    {{:ok, spec: %ParentSpec{links: links}}, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, track_id) = pad, ctx, state) do
    %Track{ssrc: ssrc, encoding: encoding} = Map.fetch!(state.inbound_tracks, track_id)

    [%{clock_rate: clock_rate} | _] =
      for mapping <- state.mappings, mapping.track_id == track_id, do: mapping

    %{track_enabled: track_enabled, extensions: extensions} = ctx.pads[pad].options

    spec = %ParentSpec{
      children: %{
        {:track_filter, track_id} => %Membrane.WebRTC.TrackFilter{enabled: track_enabled}
      },
      links: [
        link(:rtp)
        |> via_out(Pad.ref(:output, ssrc),
          options: [encoding: encoding, extensions: extensions, clock_rate: clock_rate]
        )
        |> to({:track_filter, track_id})
        |> via_out(:output)
        |> to_bin_output(pad)
      ]
    }

    {{:ok, spec: spec}, state}
  end

  @impl true
  def handle_notification({:new_rtp_stream, ssrc, pt}, _from, _ctx, state) do
    [%{encoding_name: encoding} | _] =
      for mapping <- state.mappings, mapping.payload_type == pt, do: mapping

    mid = Map.fetch!(state.ssrc_to_mid, ssrc)
    track = Map.fetch!(state.inbound_tracks, mid)
    track = %Track{track | ssrc: ssrc, encoding: encoding}
    state = put_in(state, [:inbound_tracks, track.id], track)
    {{:ok, notify: {:new_track, track.id, encoding}}, state}
  end

  @impl true
  def handle_notification({:handshake_init_data, _component_id, fingerprint}, _from, _ctx, state) do
    {:ok, %{state | dtls_fingerprint: {:sha256, hex_dump(fingerprint)}}}
  end

  @impl true
  def handle_notification({:local_credentials, credentials}, _from, _ctx, state) do
    [ice_ufrag, ice_pwd] = String.split(credentials, " ")

    state = Map.put(state, :ice, %{ufrag: ice_ufrag, pwd: ice_pwd})

    offer =
      SDP.create_offer(
        inbound_tracks: Map.values(state.outbound_tracks),
        outbound_tracks: Map.values(%{}),
        video_codecs: state.video_codecs,
        audio_codecs: state.audio_codecs,
        use_default_codecs: state.use_default_codecs,
        ice_ufrag: ice_ufrag,
        ice_pwd: ice_pwd,
        fingerprint: state.dtls_fingerprint,
        mappings: state.track_id_to_mapping
      )

    only_media = offer.media |> Enum.map(& &1.type)

    actions = [notify: {:signal, {:server_tracks, only_media}}]

    {{:ok, actions}, state}
  end

  @impl true
  def handle_notification({:new_candidate_full, cand}, _from, _ctx, state) do
    state = Map.update!(state, :candidates, &[cand | &1])
    {{:ok, notify_candidates([cand])}, state}
  end

  @impl true
  def handle_notification(:candidate_gathering_done, _from, _ctx, state) do
    {:ok, %{state | candidate_gathering_state: :done}}
  end

  @impl true
  def handle_notification({:vad, _val} = msg, _from, _ctx, state) do
    {{:ok, notify: msg}, state}
  end

  @impl true
  def handle_notification(_notification, _from, _ctx, state) do
    {:ok, state}
  end

  defp add_mappings_to_state(tracks_mappings, state) do
  end

  defp get_inbound_tracks_from_sdp(sdp) do
    send_only_sdp_media = SDP.filter_sdp_media(sdp, &(:sendonly in &1.attributes))

    stream_id = Track.stream_id()

    tracks_mappings =
      Enum.map(send_only_sdp_media, &SDP.create_track_from_sdp_media(&1, stream_id))

    inbound_tracks = Enum.map(tracks_mappings, & &1.track)

    mappings = Enum.map(tracks_mappings, & &1.mapping)

    {inbound_tracks, mappings}
  end

  defp new_tracks?(inbound_tracks, state) do
    state_tracks =
      Map.values(state.inbound_tracks) |> Enum.reduce([], &(&2 ++ [&1.ssrc])) |> List.flatten()

    Enum.reduce(inbound_tracks, [], &(&2 ++ [&1.ssrc]))
    |> Enum.map(&(&1 in state_tracks))
    |> Enum.all?()
    |> Kernel.not()
  end

  defp set_inbound_tracks(tracks, state) do
    tracks = Map.new(tracks, &{&1.id, &1})
    Map.put(state, :inbound_tracks, tracks)
  end

  defp set_ssrc_to_mid(inbound_tracks, state) do
    ssrc_to_mid =
      inbound_tracks
      |> Enum.map(fn track ->
        mid = track.id
        ssrc = track.ssrc
        {ssrc, mid}
      end)
      |> Enum.into(%{})

    %{state | ssrc_to_mid: ssrc_to_mid}
  end

  defp new_tracks_change(tracks, mappings, state) do
    state = Map.put(state, :mappings, mappings)

    state = set_inbound_tracks(tracks, state)

    state = set_ssrc_to_mid(tracks, state)

    actions = [notify: {:new_tracks, tracks}]
    {actions, state}
  end

  defp get_track_id_to_mapping(mid_to_mapping, mids, tracks, type) do
    mids = Enum.filter(mids, &(&1.type === type))
    tracks = Enum.filter(tracks, &(&1.type === type))

    Enum.zip(mids, tracks)
    |> Enum.reduce(
      %{},
      &Map.merge(&2, %{elem(&1, 1).id => Map.get(mid_to_mapping, elem(&1, 0).mid)})
    )
  end

  defp add_track_id_to_mapping_in_state(sdp, state, inbound_mappings) do
    track_id_to_mapping = Enum.reduce(inbound_mappings, %{}, &Map.merge(&2, %{&1.track_id => &1}))
    mid_to_mapping = SDP.get_mid_to_mapping(sdp)
    inbound_mids = Enum.map(inbound_mappings, & &1.mid)
    outbound_mids = Map.values(mid_to_mapping) |> Enum.filter(&(&1.mid not in inbound_mids))

    outbound_tracks = Map.values(state.outbound_tracks)

    track_id_to_mapping =
      track_id_to_mapping
      |> Map.merge(
        get_track_id_to_mapping(mid_to_mapping, outbound_mids, outbound_tracks, :audio)
      )
      |> Map.merge(
        get_track_id_to_mapping(mid_to_mapping, outbound_mids, outbound_tracks, :video)
      )

    %{state | track_id_to_mapping: track_id_to_mapping}
  end

  defp get_mid_to_track_id(track_id_to_mappings),
    do: Enum.reduce(track_id_to_mappings, %{}, &Map.merge(&2, %{elem(&1, 1).mid => elem(&1, 0)}))

  @impl true
  def handle_other({:signal, {:sdp_offer, sdp}}, _ctx, state) do
    {:ok, sdp} = sdp |> ExSDP.parse()

    {inbound_tracks, mappings} = get_inbound_tracks_from_sdp(sdp)

    state = add_track_id_to_mapping_in_state(sdp, state, mappings)

    {link_notify, state} =
      if new_tracks?(inbound_tracks, state),
        do: new_tracks_change(inbound_tracks, mappings, state),
        else: {[], state}

    answer =
      SDP.create_answer(
        inbound_tracks: inbound_tracks,
        outbound_tracks: Map.values(state.outbound_tracks),
        ice_ufrag: state.ice.ufrag,
        ice_pwd: state.ice.pwd,
        fingerprint: state.dtls_fingerprint,
        sdp: sdp,
        video_codecs: state.video_codecs,
        audio_codecs: state.audio_codecs,
        mappings: state.track_id_to_mapping
      )

    {actions, state} =
      withl tracks_check: true <- state.inbound_tracks != %{} or state.outbound_tracks != %{},
            candidate_gathering_check: nil <- state.candidate_gathering_state do
        {[forward: [ice: :gather_candidates]], %{state | candidate_gathering_state: :in_progress}}
      else
        tracks_check: _ -> {[], state}
        candidate_gathering_check: _ -> {notify_candidates(state.candidates), state}
      end

    actions = actions ++ link_notify

    actions =
      [notify: {:mid_to_track, get_mid_to_track_id(state.track_id_to_mapping)}] ++
        [notify: {:signal, {:sdp_answer, to_string(answer)}}] ++
        set_remote_credentials(sdp) ++
        actions

    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:signal, {:candidate, candidate}}, _ctx, state) do
    {{:ok, forward: {:ice, {:set_remote_candidate, "a=" <> candidate, 1}}}, state}
  end

  @impl true
  def handle_other({:add_tracks, tracks}, _ctx, state) do
    state = add_tracks(state, :outbound_tracks, tracks)
    {{:ok, forward: {:ice, :restart_stream}}, state}
  end

  @impl true
  def handle_other({:remove_tracks, tracks_ids}, _ctx, state) do
    state = Map.update!(state, :outbound_tracks, &Map.drop(&1, tracks_ids))
    {{:ok, forward: {:ice, :restart_stream}}, state}
  end

  @impl true
  def handle_other({:enable_track, track_id}, _ctx, state) do
    {{:ok, forward: {{:track_filter, track_id}, :enable_track}}, state}
  end

  @impl true
  def handle_other({:disable_track, track_id}, _ctx, state) do
    {{:ok, forward: {{:track_filter, track_id}, :disable_track}}, state}
  end

  defp add_tracks(state, direction, tracks) do
    tracks =
      case direction do
        :outbound_tracks ->
          Track.add_ssrc(
            tracks,
            Map.values(state.inbound_tracks) ++ Map.values(state.outbound_tracks)
          )

        :inbound_tracks ->
          tracks
      end

    tracks = Map.new(tracks, &{&1.id, &1})
    Map.update!(state, direction, &Map.merge(&1, tracks))
  end

  defp notify_candidates(candidates) do
    Enum.flat_map(candidates, fn cand ->
      [notify: {:signal, {:candidate, cand, 0}}]
    end)
  end

  defp set_remote_credentials(sdp) do
    case List.first(sdp.media) do
      nil ->
        []

      media ->
        {_key, ice_ufrag} = Media.get_attribute(media, :ice_ufrag)
        {_key, ice_pwd} = Media.get_attribute(media, :ice_pwd)
        remote_credentials = ice_ufrag <> " " <> ice_pwd
        [forward: {:ice, {:set_remote_credentials, remote_credentials}}]
    end
  end

  # TODO: remove once updated to Elixir 1.12
  defp pipe_fun(term, fun), do: fun.(term)
end
