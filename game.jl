# ==============================================================================
# AMONG US - CLON MULTIJUGADOR EN JULIA (MAC OS SAFE MODE)
# ==============================================================================
using Sockets
using Serialization
using GLFW
using ModernGL
using LinearAlgebra
using Printf

# ==============================================================================
# 0. SISTEMA DE SEGURIDAD PARA MACOS (OpenGL Directo)
# ==============================================================================
# Definimos la ruta al driver gráfico de Mac para forzar la carga de funciones
const LIBGL_MAC = "/System/Library/Frameworks/OpenGL.framework/Versions/Current/OpenGL"

# Wrapper seguro para cargar matrices
function safe_glLoadMatrixf(matrix::Matrix{Float32})
    if Sys.isapple()
        try
            ccall((:glLoadMatrixf, LIBGL_MAC), Cvoid, (Ptr{Float32},), matrix)
        catch e
            glLoadMatrixf(matrix)
        end
    else
        glLoadMatrixf(matrix)
    end
end

# Wrapper seguro para colorear (Reemplaza a glMaterial)
function safe_glColor3f(r::Float64, g::Float64, b::Float64)
    if Sys.isapple()
        try
            ccall((:glColor3f, LIBGL_MAC), Cvoid, (Float32, Float32, Float32), r, g, b)
        catch e
            glColor3f(r, g, b)
        end
    else
        glColor3f(r, g, b)
    end
end

# Wrapper para Viewport (por si acaso)
function safe_glViewport(x, y, w, h)
    if Sys.isapple()
        try
            ccall((:glViewport, LIBGL_MAC), Cvoid, (Int32, Int32, Int32, Int32), x, y, w, h)
        catch e
            glViewport(x, y, w, h)
        end
    else
        glViewport(x, y, w, h)
    end
end

# ==============================================================================
# 1. ESTRUCTURAS DE DATOS
# ==============================================================================

mutable struct Bomb
    id::Int
    x::Float64
    z::Float64
    active::Bool
    timer::Float64
    deactivated::Bool
    exploded::Bool
    carrier_id::Int 
end

mutable struct PlayerState
    id::Int
    x::Float64
    y::Float64
    z::Float64
    yaw::Float64
    leg_l::Float64
    leg_r::Float64
    state::Symbol 
    carrying_bomb_id::Int
    color::Tuple{Float64, Float64, Float64}
end

mutable struct NPCState
    x::Float64
    z::Float64
    yaw::Float64
    state::Symbol
    leg_l::Float64
    leg_r::Float64
    mode::Symbol
    current_path_idx::Int
end

mutable struct GameState
    players::Dict{Int, PlayerState}
    npc::NPCState
    bombs::Vector{Bomb}
    game_over::Bool
    msg::String
end

struct ClientInput
    keys::Set{Int}
    dt::Float64
end

const WIN_W = 1280
const WIN_H = 720
const ROOM_SPACING = 20.0
const WALK_SPEED = 5.0
const TURN_SPEED = 120.0
const PICKUP_RANGE = 2.0 

# ==============================================================================
# 2. LÓGICA DEL JUEGO
# ==============================================================================

function create_initial_state()
    bombs = [
        Bomb(1, -ROOM_SPACING, 0.0, true, 120.0, false, false, 0),
        Bomb(2, 0.0, -1.5, true, 120.0, false, false, 0),
        Bomb(3, ROOM_SPACING, 0.0, true, 120.0, false, false, 0)
    ]
    npc = NPCState(0.0, 2.5, 0.0, :idle, 0.0, 0.0, :roam, 1)
    return GameState(Dict{Int, PlayerState}(), npc, bombs, false, "Esperando Jugadores...")
end

const NPC_PATH = [
    (0.0, 0.0), (0.0, 10.0), (-ROOM_SPACING, 10.0), (-ROOM_SPACING, 0.0),
    (-ROOM_SPACING, 10.0), (ROOM_SPACING, 10.0), (ROOM_SPACING, 0.0), (ROOM_SPACING, 10.0),
    (0.0, 10.0), (0.0, 0.0)
]

function check_wall_collision(x, z)
    return (x < -40 || x > 40 || z < -40 || z > 40)
end

function update_game_logic!(state::GameState, inputs::Dict{Int, ClientInput}, dt::Float64)
    if state.game_over; return; end

    # 1. Jugadores
    for (pid, input) in inputs
        if !haskey(state.players, pid); continue; end
        p = state.players[pid]
        
        move_speed = 0.0
        if GLFW.KEY_W in input.keys || GLFW.KEY_UP in input.keys; move_speed = WALK_SPEED; end
        if GLFW.KEY_S in input.keys || GLFW.KEY_DOWN in input.keys; move_speed = -WALK_SPEED; end

        turn_speed = 0.0
        if GLFW.KEY_A in input.keys || GLFW.KEY_LEFT in input.keys; turn_speed = TURN_SPEED; end
        if GLFW.KEY_D in input.keys || GLFW.KEY_RIGHT in input.keys; turn_speed = -TURN_SPEED; end

        p.yaw += turn_speed * dt
        rad = deg2rad(p.yaw)
        dx = sin(rad) * move_speed * dt
        dz = cos(rad) * move_speed * dt

        if !check_wall_collision(p.x + dx, p.z + dz)
            p.x += dx; p.z += dz
        end

        if move_speed != 0
            p.state = :walk
            t_anim = time() * 10
            p.leg_l = sin(t_anim) * 30
            p.leg_r = -sin(t_anim) * 30
        else
            p.state = :idle
            p.leg_l *= 0.9; p.leg_r *= 0.9
        end

        # Interacción (Espacio)
        if GLFW.KEY_SPACE in input.keys
            if p.carrying_bomb_id > 0
                b_idx = findfirst(b -> b.id == p.carrying_bomb_id, state.bombs)
                if b_idx !== nothing
                    b = state.bombs[b_idx]
                    b.carrier_id = 0
                    b.x = p.x + sin(rad)*0.8; b.z = p.z + cos(rad)*0.8
                    p.carrying_bomb_id = 0
                    # Zona de desactivación (Ejemplo: Derecha)
                    if (abs(b.x) > 17 && abs(b.z) < 3) 
                        b.deactivated = true; b.active = false
                    end
                end
            else
                for b in state.bombs
                    if !b.exploded && b.active && b.carrier_id == 0
                        dist = sqrt((p.x - b.x)^2 + (p.z - b.z)^2)
                        if dist < PICKUP_RANGE
                            b.carrier_id = p.id; p.carrying_bomb_id = b.id
                            break
                        end
                    end
                end
            end
        end
    end

    # 2. NPC
    npc = state.npc
    target = NPC_PATH[npc.current_path_idx]
    dx = target[1] - npc.x; dz = target[2] - npc.z
    dist = sqrt(dx^2 + dz^2)
    if dist < 0.2
        npc.current_path_idx = (npc.current_path_idx % length(NPC_PATH)) + 1
    else
        npc.yaw = rad2deg(atan(dx, dz))
        npc.x += (dx/dist) * 2.5 * dt; npc.z += (dz/dist) * 2.5 * dt
        t_anim = time() * 8
        npc.leg_l = sin(t_anim) * 25; npc.leg_r = -sin(t_anim) * 25
    end

    # 3. Bombas
    for b in state.bombs
        if b.active && !b.deactivated
            b.timer -= dt
            if b.timer <= 0
                b.exploded = true; b.active = false; state.game_over = true; state.msg = "GAME OVER: BOOM!"
            end
        end
        if b.carrier_id > 0 && haskey(state.players, b.carrier_id)
            carrier = state.players[b.carrier_id]
            b.x = carrier.x; b.z = carrier.z
        end
    end
end

# ==============================================================================
# 3. RENDERIZADO MANUAL (SIN LIGHTING PARA EVITAR ERRORES)
# ==============================================================================

# Genera matriz Frustum
function get_frustum_matrix(l, r, b, t, n, f)
    return Float32[
        (2*n)/(r-l)   0.0           0.0            0.0
        0.0           (2*n)/(t-b)   0.0            0.0
        (r+l)/(r-l)   (t+b)/(t-b)   -(f+n)/(f-n)   -1.0
        0.0           0.0           -(2*f*n)/(f-n)  0.0
    ]
end

# Genera matriz LookAt
function get_lookat_matrix(eyex, eyey, eyez, centerx, centery, centerz, upx, upy, upz)
    F = Float32[centerx - eyex, centery - eyey, centerz - eyez]
    f = normalize(F)
    UP = Float32[upx, upy, upz]
    u = normalize(UP)
    s = normalize(cross(f, u))
    u = cross(s, f)

    M = Float32[
         s[1]  u[1] -f[1]  0.0
         s[2]  u[2] -f[2]  0.0
         s[3]  u[3] -f[3]  0.0
         0.0   0.0   0.0   1.0
    ]
    
    T = Float32[
        1.0 0.0 0.0 0.0
        0.0 1.0 0.0 0.0
        0.0 0.0 1.0 0.0
        -eyex -eyey -eyez 1.0
    ]
    return T * M 
end

function draw_cube()
    glBegin(GL_QUADS)
    # Sin normales, solo geometría
    glVertex3f(-0.5,-0.5,0.5); glVertex3f(0.5,-0.5,0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(-0.5,0.5,0.5)
    glVertex3f(-0.5,-0.5,-0.5); glVertex3f(-0.5,0.5,-0.5); glVertex3f(0.5,0.5,-0.5); glVertex3f(0.5,-0.5,-0.5)
    glVertex3f(-0.5,-0.5,-0.5); glVertex3f(-0.5,-0.5,0.5); glVertex3f(-0.5,0.5,0.5); glVertex3f(-0.5,0.5,-0.5)
    glVertex3f(0.5,-0.5,-0.5); glVertex3f(0.5,0.5,-0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(0.5,-0.5,0.5)
    glVertex3f(-0.5,0.5,-0.5); glVertex3f(-0.5,0.5,0.5); glVertex3f(0.5,0.5,0.5); glVertex3f(0.5,0.5,-0.5)
    glVertex3f(-0.5,-0.5,-0.5); glVertex3f(0.5,-0.5,-0.5); glVertex3f(0.5,-0.5,0.5); glVertex3f(-0.5,-0.5,0.5)
    glEnd()
end

function draw_character(x, y, z, yaw, leg_l, leg_r, color, has_cargo)
    glPushMatrix()
    glTranslatef(x, y, z)
    glRotatef(yaw, 0, 1, 0)
    
    # Torso
    safe_glColor3f(color[1], color[2], color[3])
    glPushMatrix(); glTranslatef(0, 0.9, 0); glScalef(0.7, 1.0, 0.4); draw_cube(); glPopMatrix()
    
    # Cabeza
    safe_glColor3f(color[1]*1.2, color[2]*1.2, color[3]*1.2)
    glPushMatrix(); glTranslatef(0, 1.6, 0); glScalef(0.5, 0.5, 0.5); draw_cube(); glPopMatrix()

    # Piernas
    safe_glColor3f(color[1], color[2], color[3])
    glPushMatrix(); glTranslatef(-0.2, 0.4, 0); glRotatef(leg_l, 1, 0, 0); glTranslatef(0, -0.4, 0); glScalef(0.25, 0.8, 0.25); draw_cube(); glPopMatrix()
    glPushMatrix(); glTranslatef(0.2, 0.4, 0); glRotatef(leg_r, 1, 0, 0); glTranslatef(0, -0.4, 0); glScalef(0.25, 0.8, 0.25); draw_cube(); glPopMatrix()

    # Carga
    if has_cargo
        safe_glColor3f(1.0, 1.0, 0.0) # Amarillo
        glPushMatrix(); glTranslatef(0, 1.0, 0.35); glScalef(0.4, 0.4, 0.4); draw_cube(); glPopMatrix()
    end
    glPopMatrix()
end

function render_scene(state::GameState, my_id::Int, window::GLFW.Window)
    fb_w, fb_h = GLFW.GetFramebufferSize(window)
    safe_glViewport(0, 0, fb_w, fb_h)
    
    # Color de fondo (Azul cielo claro)
    glClearColor(0.5, 0.7, 1.0, 1.0)
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)
    
    glMatrixMode(GL_MODELVIEW)
    glLoadIdentity()

    # Cámara
    cam_x, cam_z, cam_yaw = 0.0, 0.0, 0.0
    if my_id != -1 && haskey(state.players, my_id)
        p = state.players[my_id]; cam_x = p.x; cam_z = p.z; cam_yaw = p.yaw
    end
    
    view_mat = Matrix{Float32}(I, 4, 4)
    if my_id == -1
        view_mat = get_lookat_matrix(0.0, 30.0, 20.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)
    else
        ex = cam_x - 8 * sin(deg2rad(cam_yaw))
        ez = cam_z - 8 * cos(deg2rad(cam_yaw))
        view_mat = get_lookat_matrix(ex, 10.0, ez, cam_x, 1.0, cam_z, 0.0, 1.0, 0.0)
    end
    
    safe_glLoadMatrixf(view_mat)

    # Suelo (Gris)
    safe_glColor3f(0.8, 0.8, 0.8)
    glBegin(GL_QUADS)
    glVertex3f(-50, 0, -50); glVertex3f(50, 0, -50); glVertex3f(50, 0, 50); glVertex3f(-50, 0, 50)
    glEnd()

    # Zona Verde (Desactivación)
    safe_glColor3f(0.5, 0.9, 0.5)
    glBegin(GL_QUADS)
    glVertex3f(17, 0.05, -3); glVertex3f(23, 0.05, -3); glVertex3f(23, 0.05, 3); glVertex3f(17, 0.05, 3)
    glEnd()

    # Jugadores
    for (pid, p) in state.players; draw_character(p.x, p.y, p.z, p.yaw, p.leg_l, p.leg_r, p.color, p.carrying_bomb_id > 0); end
    
    # NPC
    npc = state.npc
    draw_character(npc.x, 2.5, npc.z, npc.yaw, npc.leg_l, npc.leg_r, (0.9, 0.2, 0.2), false)

    # Bombas en el suelo
    for b in state.bombs
        if b.active && !b.exploded && b.carrier_id == 0
            # Verde si desactivada, Amarilla si activa
            if b.deactivated
                safe_glColor3f(0.2, 1.0, 0.2)
            else
                safe_glColor3f(1.0, 1.0, 0.0)
            end
            glPushMatrix(); glTranslatef(b.x, 0.25, b.z); glScalef(0.5, 0.5, 0.5); draw_cube(); glPopMatrix()
        end
    end
end

# ==============================================================================
# 4. EJECUCIÓN
# ==============================================================================

function run_server(port::Int)
    println(">>> Iniciando SERVIDOR en el puerto $port")
    server = listen(IPv4(0), port)
    state = create_initial_state()
    clients = Dict{Int, TCPSocket}()
    client_inputs = Dict{Int, ClientInput}()
    next_id = 1

    @async begin
        while true
            sock = accept(server)
            id = next_id; next_id += 1
            println(">>> Cliente conectado: ID $id")
            color = (rand(), rand(), rand())
            state.players[id] = PlayerState(id, 0.0, 0.0, -5.0, 0.0, 0.0, 0.0, :idle, 0, color)
            clients[id] = sock
            @async begin
                try
                    while isopen(sock); input = deserialize(sock); client_inputs[id] = input; end
                catch e
                    delete!(state.players, id); delete!(clients, id); delete!(client_inputs, id)
                end
            end
        end
    end

    GLFW.Init()
    # Pide OpenGL 2.1 explícitamente (Compatible con Mac Legacy)
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 2); GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 1)
    
    window = GLFW.CreateWindow(800, 600, "SERVER - SPECTATOR")
    GLFW.MakeContextCurrent(window)
    glEnable(GL_DEPTH_TEST)
    # NOTA: NO habilitamos GL_LIGHTING para evitar crasheos en Mac

    glMatrixMode(GL_PROJECTION)
    glLoadIdentity()
    fov = 60.0; aspect = 800/600; zNear = 0.1; zFar = 100.0
    fh = tan(deg2rad(fov) / 2) * zNear; fw = fh * aspect
    
    proj_mat = get_frustum_matrix(-fw, fw, -fh, fh, zNear, zFar)
    safe_glLoadMatrixf(proj_mat)
    
    glMatrixMode(GL_MODELVIEW)
    last_time = time()
    
    while !GLFW.WindowShouldClose(window)
        now = time(); dt = now - last_time; last_time = now
        update_game_logic!(state, client_inputs, dt)
        for (id, sock) in clients; try serialize(sock, state) catch e end; end
        render_scene(state, -1, window)
        GLFW.SwapBuffers(window); GLFW.PollEvents(); sleep(0.01)
    end
    GLFW.DestroyWindow(window)
end

function run_client(ip_str::String, port::Int)
    println(">>> Conectando a $ip_str:$port ...")
    sock = connect(IPv4(ip_str), port)
    println(">>> ¡Conectado!")
    GLFW.Init()
    GLFW.WindowHint(GLFW.CONTEXT_VERSION_MAJOR, 2); GLFW.WindowHint(GLFW.CONTEXT_VERSION_MINOR, 1)
    
    window = GLFW.CreateWindow(WIN_W, WIN_H, "CLIENTE")
    GLFW.MakeContextCurrent(window)
    glEnable(GL_DEPTH_TEST)

    glMatrixMode(GL_PROJECTION)
    glLoadIdentity()
    fov = 60.0; aspect = WIN_W/WIN_H; zNear = 0.1; zFar = 100.0
    fh = tan(deg2rad(fov) / 2) * zNear; fw = fh * aspect
    proj_mat = get_frustum_matrix(-fw, fw, -fh, fh, zNear, zFar)
    safe_glLoadMatrixf(proj_mat)
    
    glMatrixMode(GL_MODELVIEW)
    local_state = nothing
    
    @async begin
        while isopen(sock)
            try 
                local_state = deserialize(sock) 
            catch e
                break 
            end 
        end
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
        target_id = isempty(local_state.players) ? -1 : first(keys(local_state.players))
        if !isempty(local_state.msg); GLFW.SetWindowTitle(window, local_state.msg); end
        render_scene(local_state, target_id, window)
        GLFW.SwapBuffers(window); GLFW.PollEvents()
    end
    GLFW.DestroyWindow(window)
end

if length(ARGS) < 1
    println("Uso: julia game.jl server <port>  O  julia game.jl client <ip> <port>")
else
    if ARGS[1] == "server"; run_server(parse(Int, ARGS[2]))
    elseif ARGS[1] == "client"; run_client(ARGS[2], parse(Int, ARGS[3]))
    end
end