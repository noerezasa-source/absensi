import 'package:supabase/supabase.dart';
import 'dart:io';

Future<void> main() async {
  final supabase = SupabaseClient(
    'https://oovtwiioyejefifsgrtj.supabase.co',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9vdnR3aWlveWVqZWZpZnNncnRqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODAwMTY0MTYsImV4cCI6MjA5NTU5MjQxNn0.BpXzBmlvLZX7f4bRK8IG_JHUKU5qHTsHQ1A2VL-eQZM'
  );

  final res = await supabase.from('rfid_cards').select();
  print('Total RFID Cards: ${res.length}');
  for (var row in res) {
    print(row);
  }
}
