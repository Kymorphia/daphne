module daphne_app;

import gst.global : gstInit = init_;

import daphne;
import library;

int main(string[] args)
{
	gstInit(args);

  auto daphne = new Daphne;
  daphne.run(args);

  return daphne.aborted ? 1 : 0;
}
