import 'dart:ui';
import 'package:flutter/material.dart';
import 'sender_screen.dart';
import 'receiver_screen.dart';
import '../main.dart'; // To access appThemeNotifier

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF09090B) : const Color(0xFFF8FAFC),
      body: Stack(
        children: [
          // Background Aurora Effects
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isDark ? const Color(0xFF3B82F6) : const Color(0xFF93C5FD)).withAlpha(isDark ? 30 : 80),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            right: -50,
            child: Container(
              width: 500,
              height: 500,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (isDark ? const Color(0xFF8B5CF6) : const Color(0xFFC4B5FD)).withAlpha(isDark ? 30 : 80),
              ),
            ),
          ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 120, sigmaY: 120),
              child: Container(
                color: Colors.transparent,
              ),
            ),
          ),
          
          SafeArea(
            child: Stack(
              children: [
                // Top Right Menu
                Positioned(
                  top: 16,
                  right: 16,
                  child: _buildPopupMenu(context, isDark),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Spacer(),
                          // Hero Section
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: isDark ? Colors.white.withAlpha(10) : Colors.black.withAlpha(5),
                                borderRadius: BorderRadius.circular(32),
                                border: Border.all(
                                  color: isDark ? Colors.white.withAlpha(20) : Colors.black.withAlpha(20),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: isDark ? const Color(0xFF3B82F6).withAlpha(30) : const Color(0xFF3B82F6).withAlpha(15),
                                    blurRadius: 40,
                                    spreadRadius: 10,
                                  )
                                ]
                              ),
                              child: Icon(
                                Icons.swap_horizontal_circle_rounded,
                                size: 80,
                                color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                              ),
                            ),
                          ),
                          const SizedBox(height: 40),
                          Text(
                            'AirShare',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 56,
                              fontWeight: FontWeight.w900,
                              color: isDark ? Colors.white : const Color(0xFF0F172A),
                              letterSpacing: -1.5,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Lightning fast, peer-to-peer file sharing\nacross all your devices.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 18,
                              height: 1.5,
                              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569),
                            ),
                          ),
                          const SizedBox(height: 64),

                          // Action Cards
                          _buildActionCard(
                            context: context,
                            isDark: isDark,
                            title: 'Send Files',
                            subtitle: 'Share securely via PIN',
                            icon: Icons.upload_rounded,
                            primaryColor: isDark ? const Color(0xFF3B82F6) : const Color(0xFF2563EB),
                            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SenderScreen())),
                          ),
                          const SizedBox(height: 20),
                          _buildActionCard(
                            context: context,
                            isDark: isDark,
                            title: 'Receive Files',
                            subtitle: 'Enter PIN to download',
                            icon: Icons.download_rounded,
                            primaryColor: isDark ? const Color(0xFF8B5CF6) : const Color(0xFF7C3AED),
                            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ReceiverScreen())),
                          ),
                          const Spacer(),
                          
                          // Footer
                          Padding(
                            padding: const EdgeInsets.only(bottom: 24.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text('Built with 💙 by ', style: TextStyle(color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B))),
                                Text('@nv.fate',
                                    style: TextStyle(
                                        color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB), 
                                        fontWeight: FontWeight.bold,
                                    )),
                              ],
                            ),
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required BuildContext context,
    required bool isDark,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color primaryColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        hoverColor: primaryColor.withAlpha(isDark ? 20 : 10),
        splashColor: primaryColor.withAlpha(isDark ? 40 : 20),
        highlightColor: primaryColor.withAlpha(isDark ? 20 : 10),
        child: Ink(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B).withAlpha(150) : Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            ),
            boxShadow: [
              BoxShadow(
                color: isDark ? Colors.black.withAlpha(50) : const Color(0xFF94A3B8).withAlpha(30),
                blurRadius: 24,
                offset: const Offset(0, 8),
              )
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: primaryColor.withAlpha(isDark ? 30 : 20),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 32, color: primaryColor),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                color: isDark ? const Color(0xFF475569) : const Color(0xFFCBD5E1),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPopupMenu(BuildContext context, bool isDark) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert_rounded, color: isDark ? Colors.white : const Color(0xFF0F172A), size: 28),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      elevation: 8,
      offset: const Offset(0, 40),
      onSelected: (value) {
        if (value == 'theme') {
          appThemeNotifier.value = isDark ? ThemeMode.light : ThemeMode.dark;
        } else if (value == 'download') {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download feature coming soon!')));
        } else if (value == 'about') {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App link coming soon!')));
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'theme',
          child: Row(
            children: [
              Icon(isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, color: isDark ? const Color(0xFFFBBF24) : const Color(0xFF6366F1)),
              const SizedBox(width: 12),
              Text(isDark ? 'Light Theme' : 'Dark Theme', style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'download',
          child: Row(
            children: [
              Icon(Icons.download_rounded, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
              const SizedBox(width: 12),
              Text('Downloads', style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A))),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'about',
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
              const SizedBox(width: 12),
              Text('About', style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A))),
            ],
          ),
        ),
      ],
    );
  }
}
