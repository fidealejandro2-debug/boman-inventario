import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Boman Sport — Inventario",
  description: "Sistema de inventario de producto terminado",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body>{children}</body>
    </html>
  );
}
