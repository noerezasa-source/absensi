import 'package:supabase/supabase.dart';

Future<void> main() async {
  final supabase = SupabaseClient(
    'https://oovtwiioyejefifsgrtj.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM',
  );

  print('=== LISTING ALL TABLES IN PUBLIC SCHEMA ===');
  try {
    // We can run an RPC if it exists, or let's select from some tables
    final response = await supabase.from('organization_members').select('id').limit(1);
    print('✅ Can access organization_members: OK');
  } catch (e) {
    print('❌ Error accessing organization_members: $e');
  }

  try {
    final response = await supabase.from('user_profiles').select('id').limit(1);
    print('✅ Can access user_profiles: OK');
  } catch (e) {
    print('❌ Error accessing user_profiles: $e');
  }
}
