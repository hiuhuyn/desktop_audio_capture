import 'package:flutter/material.dart';

/// Widget hiển thị decibel với progress bar và số
class DecibelDisplay extends StatelessWidget {
  final double decibel; // -120 to 0 dB
  final String label;
  final bool isActive;

  const DecibelDisplay({
    super.key,
    required this.decibel,
    required this.label,
    this.isActive = false,
  });

  /// Convert decibel (-120 to 0) to progress (0.0 to 1.0)
  double _decibelToProgress(double db) {
    // Normalize: -120 dB = 0.0, 0 dB = 1.0
    return ((db + 120.0) / 120.0).clamp(0.0, 1.0);
  }

  /// Get color based on decibel level
  Color _getColor(double db) {
    if (db >= -20) {
      return Colors.red; // Very loud
    } else if (db >= -40) {
      return Colors.orange; // Loud
    } else if (db >= -60) {
      return Colors.yellow.shade700; // Moderate
    } else if (db >= -80) {
      return Colors.green; // Quiet
    } else {
      return Colors.grey; // Very quiet/Silence
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _decibelToProgress(decibel);
    final color = _getColor(decibel);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                if (!isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Inactive',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Decibel value
            Row(
              children: [
                Text(
                  '${decibel.toStringAsFixed(1)}',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                ),
                const SizedBox(width: 4),
                Text(
                  'dB',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.grey.shade600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            const SizedBox(height: 4),
            // Level indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Silence',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade600,
                  ),
                ),
                Text(
                  'Loud',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

