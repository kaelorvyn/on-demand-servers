package com.kaelorvyn.ondemand;

import net.citizensnpcs.api.CitizensAPI;
import net.citizensnpcs.api.npc.NPC;
import net.citizensnpcs.trait.CommandTrait;
import org.bukkit.Bukkit;
import org.bukkit.ChatColor;
import org.bukkit.configuration.ConfigurationSection;
import org.bukkit.configuration.file.YamlConfiguration;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerInteractEntityEvent;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.plugin.java.JavaPlugin;
import org.bukkit.plugin.messaging.PluginMessageListener;
import org.bukkit.scheduler.BukkitTask;

import java.io.IOException;
import java.io.File;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public final class OnDemandPlugin extends JavaPlugin implements Listener, PluginMessageListener {
    private final HttpClient http = HttpClient.newHttpClient();
    private final Map<Integer, String> npcTargets = new HashMap<>();
    private String mode;
    private String service;
    private String controller;
    private String loginTarget;
    private int loginDelayTicks;
    private int idleSeconds;
    private boolean autoStop;
    private long emptySince;

    @Override public void onEnable() {
        saveDefaultConfig();
        mode = getConfig().getString("mode", "lifecycle").toLowerCase();
        service = getConfig().getString("service", "");
        controller = getConfig().getString("controller", "http://127.0.0.1:8791");
        idleSeconds = Math.max(10, getConfig().getInt("idle-seconds", 180));
        autoStop = mode.equals("lifecycle") || (mode.equals("lobby") && getConfig().getBoolean("auto-stop", false));
        loginTarget = getConfig().getString("login-target", "lobby");
        loginDelayTicks = Math.max(1, getConfig().getInt("login-delay-ticks", 60));
        if (mode.equals("lobby")) loadCitizensCommands();
        Bukkit.getPluginManager().registerEvents(this, this);
        getServer().getMessenger().registerOutgoingPluginChannel(this, "BungeeCord");
        if (mode.equals("lifecycle")) startHeartbeat();
        if (autoStop) startIdleMonitor();
        getLogger().info("OnDemandServers enabled: " + mode);
    }

    private void startIdleMonitor() {
        Bukkit.getScheduler().runTaskTimer(this, () -> {
            if (Bukkit.getOnlinePlayers().isEmpty()) {
                if (emptySince == 0L) {
                    emptySince = System.currentTimeMillis();
                } else if (System.currentTimeMillis() - emptySince >= idleSeconds * 1000L) {
                    emptySince = 0L;
                    Bukkit.dispatchCommand(Bukkit.getConsoleSender(), "stop");
                }
            } else {
                emptySince = 0L;
            }
        }, 40L, 20L);
    }

    private void startHeartbeat() {
        Bukkit.getScheduler().runTaskTimerAsynchronously(this, () -> {
            boolean ready = Bukkit.getCurrentTick() > getConfig().getInt("ready-delay-ticks", 40);
            post("/v1/heartbeat", "{\"service\":\"" + escape(service) + "\",\"ready\":" + ready + ",\"players\":" + Bukkit.getOnlinePlayers().size() + "}");
        }, 40L, 100L);
    }

    @EventHandler public void join(PlayerJoinEvent event) {
        if (mode.equals("login")) {
            Bukkit.getScheduler().runTaskLater(this, () -> requestAndConnect(event.getPlayer(), loginTarget), loginDelayTicks);
        }
    }

    @EventHandler public void npcClick(PlayerInteractEntityEvent event) {
        if (!mode.equals("lobby") || !CitizensAPI.hasImplementation()) return;
        NPC npc = CitizensAPI.getNPCRegistry().getNPC(event.getRightClicked());
        String target = npc == null ? null : npcTargets.get(npc.getId());
        if (target == null) return;
        event.setCancelled(true);
        requestAndConnect(event.getPlayer(), target);
    }

    private void loadCitizensCommands() {
        File saves = new File("plugins/Citizens/saves.yml");
        if (!saves.isFile()) {
            getLogger().warning("Citizens saves.yml not found; NPC routing disabled");
            return;
        }
        ConfigurationSection npcs = YamlConfiguration.loadConfiguration(saves).getConfigurationSection("npc");
        if (npcs == null) return;
        for (String id : npcs.getKeys(false)) {
            List<Map<?, ?>> commands = npcs.getMapList(id + ".traits.commandtrait.commands");
            String command = commands.isEmpty() ? "" : String.valueOf(commands.get(0).get("command"));
            String[] parts = command.trim().split("\\s+");
            if (parts.length == 2 && parts[0].equalsIgnoreCase("server")) {
                try { npcTargets.put(Integer.parseInt(id), parts[1]); }
                catch (NumberFormatException ignored) { }
            }
        }
        getLogger().info("Loaded " + npcTargets.size() + " Citizens server NPC routes");
    }

    private void requestAndConnect(Player player, String target) {
        player.sendMessage(ChatColor.YELLOW + "正在开启服务器，请稍等...");
        Bukkit.getScheduler().runTaskAsynchronously(this, () -> {
            post("/v1/start", "{\"service\":\"" + escape(target) + "\"}");
            for (int i = 0; i < 90; i++) {
                String result = get("/v1/status?service=" + target);
                if (result.contains("\"state\": \"ONLINE\"")) {
                    Bukkit.getScheduler().runTask(this, () -> connect(player, target));
                    return;
                }
                try { Thread.sleep(2000L); } catch (InterruptedException ignored) { return; }
            }
            Bukkit.getScheduler().runTask(this, () -> player.sendMessage(ChatColor.RED + "服务器启动超时，请稍后重试。"));
        });
    }

    private void connect(Player player, String target) {
        if (!player.isOnline()) return;
        try {
            var out = new java.io.ByteArrayOutputStream();
            var data = new java.io.DataOutputStream(out);
            data.writeUTF("Connect"); data.writeUTF(target); data.close();
            player.sendPluginMessage(this, "BungeeCord", out.toByteArray());
        } catch (IOException e) { getLogger().warning("Connect failed: " + e.getMessage()); }
    }

    private String get(String path) { return request("GET", path, ""); }
    private String post(String path, String body) { return request("POST", path, body); }
    private String request(String method, String path, String body) {
        try {
            HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(controller + path));
            if (method.equals("POST")) builder.header("Content-Type", "application/json").POST(HttpRequest.BodyPublishers.ofString(body));
            else builder.GET();
            return http.send(builder.build(), HttpResponse.BodyHandlers.ofString()).body();
        } catch (Exception e) { return ""; }
    }
    private static String escape(String value) { return value.replace("\\", "\\\\").replace("\"", "\\\""); }
    @Override public void onPluginMessageReceived(String channel, Player player, byte[] message) { }
}
