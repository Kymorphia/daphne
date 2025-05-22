module daphne_app;

import gda.global : gdaInit = init_;
import gst.global : gstInit = init_;

import daphne;
import library;

int main(string[] args)
{
  gdaInit;
	gstInit(args);

  auto daphne = new Daphne;
  daphne.run(args);

  return daphne.aborted ? 1 : 0;
}
