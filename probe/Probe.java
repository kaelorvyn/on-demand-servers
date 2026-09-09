import java.io.File;
import java.util.List;
import java.util.Map;
import org.bukkit.configuration.ConfigurationSection;
import org.bukkit.configuration.file.YamlConfiguration;

public final class Probe {
    public static void main(String[] args) {
        File saves = new File("D:\\MC\\server\\[25567]大厅\\plugins\\Citizens\\saves.yml");
        System.out.println("isFile=" + saves.isFile());
        YamlConfiguration cfg = YamlConfiguration.loadConfiguration(saves);
        ConfigurationSection npcs = cfg.getConfigurationSection("npc");
        System.out.println("npcSection=" + (npcs == null ? "null" : npcs.getKeys(false)));
        if (npcs == null) return;
        int routes = 0;
        for (String id : npcs.getKeys(false)) {
            String raw = npcs.getString(id + ".traits.commandtrait.commands.0.command", "<missing>");
            System.out.println("id=" + id + " raw=[" + raw + "]");
            List<Map<?, ?>> commands = npcs.getMapList(id + ".traits.commandtrait.commands");
            Object viaList = commands.isEmpty() ? null : commands.get(0).get("command");
            System.out.println("  viaList=[" + viaList + "] class=" + (commands.isEmpty() ? "-" : commands.get(0).getClass().getName()));
            if (viaList instanceof String s && s.startsWith("server ")) routes++;
        }
        System.out.println("routes=" + routes);
    }
}
