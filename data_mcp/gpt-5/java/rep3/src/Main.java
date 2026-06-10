public class Main {
    public static void main(String[] args) throws Exception {
        int port = 8080;
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--port") && i + 1 < args.length) {
                try { port = Integer.parseInt(args[i+1]); } catch (NumberFormatException e) { System.err.println("Invalid port"); System.exit(1);} 
                i++;
            }
        }
        TodoServer server = new TodoServer(port);
        server.start();
    }
}
