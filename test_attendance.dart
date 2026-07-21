import 'package:supabase/supabase.dart';

Future<void> main() async {
  final supabase = SupabaseClient(
    'https://oovtwiioyejefifsgrtj.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM'
  );

  final mondayStr = '2026-07-20';
  final fridayStr = '2026-07-24';
  final organizationId = 1; // Assuming REJA BARU is org 1 based on previous logs

  try {
    final allRecords = await supabase.from('attendance_records').select('id, organization_member_id, attendance_date, work_duration_minutes');
    print('Total records in attendance_records across all time and orgs: ${allRecords.length}');
    for (var row in allRecords.take(5)) {
      print('Record: $row');
    }

  } catch (e) {
    print('Error: $e');
  }
}
