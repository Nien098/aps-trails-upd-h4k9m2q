import 'package:flutter/material.dart';

/// A compact, high-contrast direction/alert banner anchored at the bottom. It
/// only covers a small part of the screen so the map above it stays visible
/// and interactable; the walker can tap the dismiss button to close it.
class BigActionCard extends StatelessWidget {
  const BigActionCard({
    super.key,
    required this.color,
    required this.icon,
    required this.text,
    required this.onRepeat,
    required this.onDismiss,
    this.dismissIcon = Icons.close,
    this.dismissTooltip = 'Close',
    this.number,
  });

  final Color color;
  final IconData icon;
  final String text;
  final VoidCallback onRepeat;
  final VoidCallback onDismiss;
  final IconData dismissIcon;
  final String dismissTooltip;

  /// This cue's 1-based position in the trail's stack order, shown as a
  /// small badge on the icon — matches its map marker number, so it's
  /// obvious which cue just fired without needing to check the map. Null
  /// (no badge) for the off-route/stillness alert cards, which aren't cues.
  final int? number;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      right: 8,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Material(
            color: color,
            borderRadius: BorderRadius.circular(20),
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(icon, size: 48, color: Colors.white),
                      if (number != null)
                        Positioned(
                          top: -6,
                          left: -6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('#$number',
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: color)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 26,
                        height: 1.1,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Repeat',
                        onPressed: onRepeat,
                        icon: const Icon(Icons.volume_up,
                            size: 30, color: Colors.white),
                      ),
                      IconButton(
                        tooltip: dismissTooltip,
                        onPressed: onDismiss,
                        icon: Icon(dismissIcon, size: 30, color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
