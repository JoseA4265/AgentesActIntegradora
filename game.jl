using Sockets
using Serialization
using GLFW
using ModernGL
using LinearAlgebra
using Printf

# ==============================================================================
# 0. GL MAC WRAPPERS (NO TOCAR)
# ==============================================================================
const LIBGL_MAC = "/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL"
const GLbitfield = UInt32
const GLenum = UInt32
const GLfloat = Float32
const GLint = Int32

function glBegin(mode::Integer); ccall((:glBegin, LIBGL_MAC), Cvoid, (GLenum,), mode); end
function glEnd(); ccall((:glEnd, LIBGL_MAC), Cvoid, ()); end
function glVertex3f(x::Real, y::Real, z::Real); ccall((:glVertex3f, LIBGL_MAC), Cvoid, (GLfloat, GLfloat, GLfloat), x, y, z); end
function glColor3f(r::Real, g::Real, b::Real); ccall((:glColor3f, LIBGL_MAC), Cvoid, (GLfloat, GLfloat, GLfloat), r, g, b); end
function glMatrixMode(mode::Integer); ccall((:glMatrixMode, LIBGL_MAC), Cvoid, (GLenum,), mode); end
function glLoadIdentity(); ccall((:glLoadIdentity, LIBGL_MAC), Cvoid, ()); end
function glPushMatrix(); ccall((:glPushMatrix, LIBGL_MAC), Cvoid, ()); end
function glPopMatrix(); ccall((:glPopMatrix, LIBGL_MAC), Cvoid, ()); end
function glTranslatef(x::Real, y::Real, z::Real); ccall((:glTranslatef, LIBGL_MAC), Cvoid, (GLfloat, GLfloat, GLfloat), x, y, z); end
function glRotatef(angle::Real, x::Real, y::Real, z::Real); ccall((:glRotatef, LIBGL_MAC), Cvoid, (GLfloat, GLfloat, GLfloat, GLfloat), angle, x, y, z); end
function glScalef(x::Real, y::Real, z::Real); ccall((:glScalef, LIBGL_MAC), Cvoid, (GLfloat, GLfloat, GLfloat), x, y, z); end
function glLoadMatrixf(m::AbstractMatrix{Float32}); ccall((:glLoadMatrixf, LIBGL_MAC), Cvoid, (Ptr{GLfloat},), m); end
function glViewport(x::Integer, y::Integer, width::Integer, height::Integer); ccall((:glViewport, LIBGL_MAC), Cvoid, (GLint, GLint, GLint, GLint), x, y, width, height); end
function glClear(mask::Integer); ccall((:glClear, LIBGL_MAC), Cvoid, (GLbitfield,), mask); end
function glClearColor(r::Real, g::Real, b::Real, a::Real); ccall((:glClearColor, LIBGL_MAC), Cvoid, (GLfloat, GLfloat, GLfloat, GLfloat), r, g, b, a); end
function glEnable(cap::Integer); ccall((:glEnable, LIBGL_MAC), Cvoid, (GLenum,), cap); end

# ==============================================================================
# 1. ESTRUCTURAS DE DATOS Y MAPA
# ==============================================================================

# Constantes del Juego
const WIN_W = 1280
const WIN_H = 720
const ROOM_SIZE = 14.0
const ROOM_SPACING = 20.0
const FLOOR_SIZE = 90.0
const WALK_SPEED = 5.0
const TURN_SPEED = 120.0
const PICKUP_RANGE = 2.0 

mutable struct Bomb
    id::Int; x::Float64; z::Float64; active::Bool; timer::Float64; deactivated::Bool; exploded::Bool; carrier_id::Int 
end

mutable struct PlayerState
    id::Int; x::Float64; y::Float64; z::Float64; yaw::Float64; leg_l::Float64; leg_r::Float64; state::Symbol; carrying_bomb_id::Int; color::Tuple{Float64, Float64, Float64}
end

mutable struct NPCState
    x::Float64; z::Float64; yaw::Float64; state::Symbol; leg_l::Float64; leg_r::Float64; mode::Symbol; current_path_idx::Int
end

# Estructuras para el Mapa (Paredes y Pisos)
struct Wall
    cx::Float64; cy::Float64; cz::Float64; sx::Float64; sy::Float64; sz::Float64
end

struct RoomFloor
    x0::Float64; z0::Float64; x1::Float64; z1::Float64; color::Tuple{Float64, Float64, Float64}
end

mutable struct GameState
    players::Dict{Int, PlayerState}; npc::NPCState; bombs::Vector{Bomb}; game_over::Bool; msg::String
    walls::Vector{Wall}
    room_floors::Vector{RoomFloor}
end

struct ClientInput
    keys::Set{Int}; dt::Float64
end

# --- GENERACIÓN DEL MAPA ---
function build_map_data()
    walls = Vector{Wall}()
    room_floors = Vector{RoomFloor}()
    
    wall_h = 3.0; th = 0.25; room = ROOM_SIZE; spacing = ROOM_SPACING; door_w = 3.6
    xs = (-spacing, 0.0, spacing)

    for x in xs
        x0, x1 = x - room/2, x + room/2
        z0, z1 = -room/2, room/2
        col = (x == 0.0) ? (0.78, 0.78, 0.82) : (0.76, 0.80, 0.82)
        push!(room_floors, RoomFloor(x0, z0, x1, z1, col))
        seg = (room - door_w)/2.0
        push!(walls, Wall(x - (door_w/2 + seg/2), wall_h/2, room/2, seg, wall_h, th))
        push!(walls, Wall(x + (door_w/2 + seg/2), wall_h/2, room/2, seg, wall_h, th))
        push!(walls, Wall(x, wall_h/2, -room/2, room, wall_h, th))
        side_seg = (room - door_w)
        offset = (x == 0.0) ? 0.0 : (x < 0 ? door_w*0.5 : -door_w*0.5)
        push!(walls, Wall(x - room/2, wall_h/2, 0.0 - offset, th, wall_h, side_seg))
        push!(walls, Wall(x + room/2, wall_h/2, 0.0, th, wall_h, room))
    end
    border = FLOOR_SIZE - 2.0
    push!(walls, Wall(0.0, wall_h/2, border, FLOOR_SIZE*2, wall_h, th))
    push!(walls, Wall(0.0, wall_h/2, -border, FLOOR_SIZE*2, wall_h, th))
    push!(walls, Wall(border, wall_h/2, 0.0, th, wall_h, FLOOR_SIZE*2))
    push!(walls, Wall(-border, wall_h/2, 0.0, th, wall_h, FLOOR_SIZE*2))
    return walls, room_floors
end

# ==============================================================================
# 2. LÓGICA DEL JUEGO
# ==============================================================================

function create_initial_state()
    bombs = [Bomb(1, -ROOM_SPACING, 0.0, true, 120.0, false, false, 0), Bomb(2, 0.0, -1.5, true, 120.0, false, false, 0), Bomb(3, ROOM_SPACING, 0.0, true, 120.0, false, false, 0)]
    npc = NPCState(0.0, 2.5, 0.0, :idle, 0.0, 0.0, :roam, 1)
    walls, r_floors = build_map_data()
    return GameState(Dict{Int, PlayerState}(), npc, bombs, false, "Esperando Jugadores...", walls, r_floors)
end

const NPC_PATH = [(0.0, 0.0), (0.0, 10.0), (-ROOM_SPACING, 10.0), (-ROOM_SPACING, 0.0), (-ROOM_SPACING, 10.0), (ROOM_SPACING, 10.0), (ROOM_SPACING, 0.0), (ROOM_SPACING, 10.0), (0.0, 10.0), (0.0, 0.0)]

function check_wall_collision(x, z, walls)
    radius = 0.35
    for w in walls
        min_x = w.cx - w.sx/2 - radius; max_x = w.cx + w.sx/2 + radius
        min_z = w.cz - w.sz/2 - radius; max_z = w.cz + w.sz/2 + radius
        if (x >= min_x && x <= max_x && z >= min_z && z <= max_z); return true; end
    end
    return false
end

function update_game_logic!(state::GameState, inputs::Dict{Int, ClientInput}, dt::Float64)
    if state.game_over; return; end
    for (pid, input) in inputs
        if !haskey(state.players, pid); continue; end
        p = state.players[pid]
        move_speed = 0.0
        if GLFW.KEY_W in input.keys || GLFW.KEY_UP in input.keys; move_speed = WALK_SPEED; end
        if GLFW.KEY_S in input.keys || GLFW.KEY_DOWN in input.keys; move_speed = -WALK_SPEED; end
        turn_speed = 0.0
        if GLFW.KEY_A in input.keys || GLFW.KEY_LEFT in input.keys; turn_speed = TURN_SPEED; end
        if GLFW.KEY_D in input.keys || GLFW.KEY_RIGHT in input.keys; turn_speed = -TURN_SPEED; end
        p.yaw += turn_speed * dt; rad = deg2rad(p.yaw)
        dx = sin(rad) * move_speed * dt; dz = cos(rad) * move_speed * dt
        if !check_wall_collision(p.x + dx, p.z, state.walls); p.x += dx; end
        if !check_wall_collision(p.x, p.z + dz, state.walls); p.z += dz; end
        if move_speed != 0; p.state = :walk; t_anim = time() * 10; p.leg_l = sin(t_anim) * 30; p.leg_r = -sin(t_anim) * 30
        else; p.state = :idle; p.leg_l *= 0.9; p.leg_r *= 0.9; end
        if GLFW.KEY_SPACE in input.keys
            if p.carrying_bomb_id > 0
                b_idx = findfirst(b -> b.id == p.carrying_bomb_id, state.bombs)
                if b_idx !== nothing
                    b = state.bombs[b_idx]; b.carrier_id = 0; b.x = p.x + sin(rad)*0.8; b.z = p.z + cos(rad)*0.8
                    p.carrying_bomb_id = 0
                    if (abs(b.x) > 17 && abs(b.z) < 3); b.deactivated = true; b.active = false; end
                end
            else
                for b in state.bombs
                    if !b.exploded && b.active && b.carrier_id == 0
                        dist = sqrt((p.x - b.x)^2 + (p.z - b.z)^2)
                        if dist < PICKUP_RANGE; b.carrier_id = p.id; p.carrying_bomb_id = b.id; break; end
                    end
                end
            end
        end
    end
    npc = state.npc; target = NPC_PATH[npc.current_path_idx]
    dx = target[1] - npc.x; dz = target[2] - npc.z; dist = sqrt(dx^2 + dz^2)
    if dist < 0.2; npc.current_path_idx = (npc.current_path_idx % length(NPC_PATH)) + 1
    else; npc.yaw = rad2deg(atan(dx, dz)); npc.x += (dx/dist) * 2.5 * dt; npc.z += (dz/dist) * 2.5 * dt; t_anim = time() * 8; npc.leg_l = sin(t_anim) * 25; npc.leg_r = -sin(t_anim) * 25; end
    for b in state.bombs
        if b.active && !b.deactivated; b.timer -= dt
            if b.timer <= 0; b.exploded = true; b.active = false; state.game_over = true; state.msg = "GAME OVER: BOOM!"; end
        end
        if b.carrier_id > 0 && haskey(state.players, b.carrier_id); carrier = state.players[b.carrier_id]; b.x = carrier.x; b.z = carrier.z; end
    end
end

# ==============================================================================
# 3. RENDERIZADO (FIXED MATRICES)
# ==============================================================================

# Matriz Frustum Corregida para OpenGL
function get_frustum_matrix(l, r, b, t, n, f)
    return Float32[
        (2*n)/(r-l)   0.0           (r+l)/(r-l)    0.0;
        0.0           (2*n)/(t-b)   (t+b)/(t-b)    0.0;
        0.0           0.0           -(f+n)/(f-n)  -(2*f*n)/(f-n);
        0.0           0.0           -1.0           0.0
    ]
end

# Matriz LookAt Corregida para OpenGL (M = T * R_transposed)
function get_lookat_matrix(eyex, eyey, eyez, centerx, centery, centerz, upx, upy, upz)
    F = Float32[centerx - eyex, centery - eyey, centerz - eyez]; f = normalize(F)
    UP = Float32[upx, upy, upz]; u = normalize(UP); s = normalize(cross(f, u)); u = cross(s, f)
    
    # Rotation (Rows are basis vectors)
    R = Float32[
        s[1]  s[2]  s[3]  0.0;
        u[1]  u[2]  u[3]  0.0;
       -f[1] -f[2] -f[3]  0.0;
        0.0   0.0   0.0   1.0
    ]
    
    # Translation (Column 4)
    T = Float32[
        1.0 0.0 0.0 -eyex;
        0.0 1.0 0.0 -eyey;
        0.0 0.0 1.0 -eyez;
        0.0 0.0 0.0 1.0
    ]
    
    return R * T
end

function draw_cube()
    glBegin(GL_QUADS)
    glVertex3f(-0.5,-0.5,0.5); glVertex3f(0.5,-0.5,0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(-0.5,0.5,0.5)
    glVertex3f(-0.5,-0.5,-0.5); glVertex3f(-0.5,0.5,-0.5); glVertex3f(0.5,0.5,-0.5); glVertex3f(0.5,-0.5,-0.5)
    glVertex3f(-0.5,-0.5,-0.5); glVertex3f(-0.5,-0.5,0.5); glVertex3f(-0.5,0.5,0.5); glVertex3f(-0.5,0.5,-0.5)
    glVertex3f(0.5,-0.5,-0.5); glVertex3f(0.5,0.5,-0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(0.5,-0.5,0.5)
    glVertex3f(-0.5,0.5,-0.5); glVertex3f(-0.5,0.5,0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(0.5,0.5,-0.5)
    glVertex3f(-0.5,-0.5,-0.5); glVertex3f(0.5,-0.5,-0.5); glVertex3f(0.5,-0.5,0.5); glVertex3f(-0.5,-0.5,0.5)
    glEnd()
end

function draw_map(walls::Vector{Wall}, floors::Vector{RoomFloor})
    glColor3f(0.85, 0.85, 0.87) 
    glBegin(GL_QUADS); glVertex3f(-90.0, 0.0, -90.0); glVertex3f(90.0, 0.0, -90.0); glVertex3f(90.0, 0.0, 90.0); glVertex3f(-90.0, 0.0, 90.0); glEnd()
    for f in floors
        glColor3f(f.color[1], f.color[2], f.color[3])
        glBegin(GL_QUADS); y = 0.02
        glVertex3f(f.x0, y, f.z0); glVertex3f(f.x1, y, f.z0); glVertex3f(f.x1, y, f.z1); glVertex3f(f.x0, y, f.z1); glEnd()
    end
    glColor3f(0.47, 0.9, 0.47)
    glBegin(GL_QUADS); y = 0.03
    glVertex3f(17.5, y, -2.5); glVertex3f(22.5, y, -2.5); glVertex3f(22.5, y, 2.5); glVertex3f(17.5, y, 2.5); glEnd()
    glColor3f(0.27, 0.27, 0.28)
    for w in walls
        glPushMatrix(); glTranslatef(w.cx, w.cy, w.cz); glScalef(w.sx, w.sy, w.sz); draw_cube(); glPopMatrix()
    end
end

function draw_character(x, y, z, yaw, leg_l, leg_r, color, has_cargo)
    glPushMatrix(); glTranslatef(x, y, z); glRotatef(yaw, 0.0, 1.0, 0.0)
    glColor3f(color[1], color[2], color[3]); glPushMatrix(); glTranslatef(0.0, 0.9, 0.0); glScalef(0.7, 1.0, 0.4); draw_cube(); glPopMatrix()
    glColor3f(color[1]*1.2, color[2]*1.2, color[3]*1.2); glPushMatrix(); glTranslatef(0.0, 1.6, 0.0); glScalef(0.5, 0.5, 0.5); draw_cube(); glPopMatrix()
    glColor3f(color[1], color[2], color[3])
    glPushMatrix(); glTranslatef(-0.2, 0.4, 0.0); glRotatef(leg_l, 1.0, 0.0, 0.0); glTranslatef(0.0, -0.4, 0.0); glScalef(0.25, 0.8, 0.25); draw_cube(); glPopMatrix()
    glPushMatrix(); glTranslatef(0.2, 0.4, 0.0); glRotatef(leg_r, 1.0, 0.0, 0.0); glTranslatef(0.0, -0.4, 0.0); glScalef(0.25, 0.8, 0.25); draw_cube(); glPopMatrix()
    if has_cargo; glColor3f(1.0, 1.0, 0.0); glPushMatrix(); glTranslatef(0.0, 1.0, 0.35); glScalef(0.4, 0.4, 0.4); draw_cube(); glPopMatrix(); end
    glPopMatrix()
end

function render_scene(state::GameState, my_id::Int, window::GLFW.Window)
    fb_w, fb_h = GLFW.GetFramebufferSize(window); glViewport(0, 0, fb_w, fb_h)
    glClearColor(0.62, 0.70, 0.78, 1.0); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
    glMatrixMode(GL_MODELVIEW); glLoadIdentity()
    cam_x, cam_z, cam_yaw = 0.0, 0.0, 0.0
    if my_id != -1 && haskey(state.players, my_id)
        p = state.players[my_id]; cam_x = p.x; cam_z = p.z; cam_yaw = p.yaw
    end
    view_mat = Matrix{Float32}(I, 4, 4)
    if my_id == -1 
        view_mat = get_lookat_matrix(0.0, 40.0, 30.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    else 
        ex = cam_x - 12 * sin(deg2rad(cam_yaw)); ez = cam_z - 12 * cos(deg2rad(cam_yaw))
        view_mat = get_lookat_matrix(ex, 7.5, ez, cam_x, 1.0, cam_z, 0.0, 1.0, 0.0)
    end
    # TRUCO: Julia almacena columnas primero. OpenGL lee columnas primero.
    # Pero visualmente definimos las matrices "como se ven". 
    # Para que funcione, necesitamos pasarla TAL CUAL a glLoadMatrix.
    glLoadMatrixf(view_mat)

    draw_map(state.walls, state.room_floors)
    for (pid, p) in state.players; draw_character(p.x, p.y, p.z, p.yaw, p.leg_l, p.leg_r, p.color, p.carrying_bomb_id > 0); end
    npc = state.npc; draw_character(npc.x, 2.5, npc.z, npc.yaw, npc.leg_l, npc.leg_r, (0.9, 0.2, 0.2), false)
    for b in state.bombs
        if b.active && !b.exploded && b.carrier_id == 0
            if b.deactivated; glColor3f(0.2, 1.0, 0.2); else; glColor3f(1.0, 1.0, 0.0); end
            glPushMatrix(); glTranslatef(b.x, 0.25, b.z); glScalef(0.5, 0.5, 0.5); draw_cube(); glPopMatrix()
        end
    end
end

# ==============================================================================
# 4. EJECUCIÓN
# ==============================================================================

function run_server(port::Int, play_as_host::Bool)
    println(">>> Iniciando SERVIDOR en el puerto $port")
    println(play_as_host ? ">>> MODO: HOST & PLAY" : ">>> MODO: SPECTATOR")
    server = listen(IPv4(0), port)
    state = create_initial_state()
    clients = Dict{Int, TCPSocket}()
    client_inputs = Dict{Int, ClientInput}()
    next_id = play_as_host ? 2 : 1
    my_id = play_as_host ? 1 : -1
    if play_as_host; state.players[my_id] = PlayerState(my_id, 0.0, 0.0, -5.0, 0.0, 0.0, 0.0, :idle, 0, (0.2, 0.2, 0.9)); end

    @async begin
        while true
            sock = accept(server)
            id = next_id; next_id += 1
            println(">>> Conexión entrante. Asignando ID: $id")
            serialize(sock, id)
            color = (rand(), rand(), rand())
            state.players[id] = PlayerState(id, 0.0, 0.0, 5.0, 180.0, 0.0, 0.0, :idle, 0, color)
            clients[id] = sock
            @async begin
                try
                    while isopen(sock); input = deserialize(sock); client_inputs[id] = input; end
                catch e
                    println("Cliente $id desconectado"); delete!(state.players, id); delete!(clients, id); delete!(client_inputs, id)
                end
            end
        end
    end

    GLFW.Init()
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 2); GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 1)
    window = GLFW.CreateWindow(800, 600, play_as_host ? "SERVER - HOST (JUGANDO)" : "SERVER - ESPECTADOR")
    GLFW.MakeContextCurrent(window)
    glEnable(GL_DEPTH_TEST)

    glMatrixMode(GL_PROJECTION); glLoadIdentity()
    fov = 60.0; aspect = 800/600; zNear = 0.1; zFar = 100.0
    fh = tan(deg2rad(fov) / 2) * zNear; fw = fh * aspect
    proj_mat = get_frustum_matrix(-fw, fw, -fh, fh, zNear, zFar)
    glLoadMatrixf(proj_mat)
    
    glMatrixMode(GL_MODELVIEW); last_time = time(); host_keys = Set{Int}()

    if play_as_host
        GLFW.SetKeyCallback(window, (_, key, scancode, action, mods) -> begin
            if action == GLFW.PRESS; push!(host_keys, Int(key))
            elseif action == GLFW.RELEASE; delete!(host_keys, Int(key))
            end
        end)
    end
    
    while !GLFW.WindowShouldClose(window)
        now = time(); dt = now - last_time; last_time = now
        if play_as_host; client_inputs[my_id] = ClientInput(copy(host_keys), dt); end
        update_game_logic!(state, client_inputs, dt)
        for (id, sock) in clients; try serialize(sock, state) catch e end; end
        render_scene(state, my_id, window)
        GLFW.SwapBuffers(window); GLFW.PollEvents(); sleep(0.01)
    end
    GLFW.DestroyWindow(window)
end

function run_client(ip_str::String, port::Int)
    println(">>> Conectando a $ip_str:$port ...")
    sock = connect(IPv4(ip_str), port)
    my_id = deserialize(sock)
    println(">>> ¡Conectado! Soy el Jugador ID: $my_id")

    GLFW.Init()
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 2); GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 1)
    window = GLFW.CreateWindow(WIN_W, WIN_H, "CLIENTE (JUGADOR $my_id)")
    GLFW.MakeContextCurrent(window)
    glEnable(GL_DEPTH_TEST)

    glMatrixMode(GL_PROJECTION); glLoadIdentity()
    fov = 60.0; aspect = WIN_W/WIN_H; zNear = 0.1; zFar = 100.0
    fh = tan(deg2rad(fov) / 2) * zNear; fw = fh * aspect
    proj_mat = get_frustum_matrix(-fw, fw, -fh, fh, zNear, zFar)
    glLoadMatrixf(proj_mat)
    glMatrixMode(GL_MODELVIEW)
    
    local_state = nothing
    @async begin
        while isopen(sock); try local_state = deserialize(sock) catch e break end end
    end

    last_time = time(); keys_pressed = Set{Int}()
    GLFW.SetKeyCallback(window, (_, key, scancode, action, mods) -> begin
        if action == GLFW.PRESS; push!(keys_pressed, Int(key))
        elseif action == GLFW.RELEASE; delete!(keys_pressed, Int(key))
        end
    end)

    while !GLFW.WindowShouldClose(window)
        if local_state === nothing; GLFW.PollEvents(); continue; end
        now = time(); dt = now - last_time; last_time = now
        input = ClientInput(copy(keys_pressed), dt)
        try serialize(sock, input) catch e break end
        if !isempty(local_state.msg); GLFW.SetWindowTitle(window, local_state.msg); end
        render_scene(local_state, my_id, window)
        GLFW.SwapBuffers(window); GLFW.PollEvents()
    end
    GLFW.DestroyWindow(window)
end

if length(ARGS) < 1
    println("Uso: julia game.jl host <port>  O  julia game.jl client <ip> <port>")
else
    if ARGS[1] == "server"; run_server(parse(Int, ARGS[2]), false)
    elseif ARGS[1] == "host"; run_server(parse(Int, ARGS[2]), true)
    elseif ARGS[1] == "client"; run_client(ARGS[2], parse(Int, ARGS[3]))
    end
end
