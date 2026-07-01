package mop;

import java.lang.instrument.Instrumentation;

public class GcForcer {
    public static void premain(String args, Instrumentation inst) {
        Runtime.getRuntime().addShutdownHook(new Thread(System::gc));
    }
}
