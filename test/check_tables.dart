import 'package:supabase/supabase.dart';

Future<void> main() async {
  final supabase = SupabaseClient(
    'https://oovtwiioyejefifsgrtj.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM',
  );

  print('=== CHECKING TABLE EXISTENCE ===');
  
  try {
    print('Testing user_profiles table:');
    final up = await supabase.from('user_profiles').select('id').limit(1);
    print('  user_profiles OK: count=${up.length}');
  } catch (e) {
    print('  user_profiles ERROR: $e');
  }

  try {
    print('Testing profiles table:');
    final p = await supabase.from('profiles').select('id').limit(1);
    print('  profiles OK: count=${p.length}');
  } catch (e) {
    print('  profiles ERROR: $e');
  }

  try {
    print('Testing organization_members table:');
    final om = await supabase.from('organization_members').select('id, user_id').limit(1);
    print('  organization_members OK: count=${om.length}');
  } catch (e) {
    print('  organization_members ERROR: $e');
  }
}
