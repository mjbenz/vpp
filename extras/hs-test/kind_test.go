package main

import (
	"time"

	. "fd.io/hs-test/infra/infra_kind"
	. "github.com/onsi/ginkgo/v2"
)

func init() {
	RegisterKindTests(KindIperfVclTest, NginxRpsTest)
}

func KindIperfVclTest(s *KindSuite) {
	s.DeployServerClient(s.ImageNames.HstVpp, s.ImageNames.HstVpp, s.PodNames.ServerVpp, s.PodNames.ClientVpp)

	vclPath := "/vcl.conf"
	ldpPath := "/usr/lib/libvcl_ldpreload.so"

	// temporary workaround
	symLink := "for file in /usr/lib/*.so; do\n" +
		"if [ -e \"$file\" ]; then\n" +
		"base=$(basename \"$file\")\n" +
		"newlink=\"/usr/lib/${base}.25.06\"\n" +
		"ln -s \"$file\" \"$newlink\"\n" +
		"fi\n" +
		"done"

	vclConf := "echo \"vcl {\n" +
		"rx-fifo-size 4000000\n" +
		"tx-fifo-size 4000000\n" +
		"app-scope-local\n" +
		"app-scope-global\n" +
		"app-socket-api abstract:vpp/session\n" +
		"}\" > /vcl.conf"

	s.Exec(s.PodNames.ClientVpp, s.ContainerNames.Client, []string{"/bin/bash", "-c", symLink})
	s.Exec(s.PodNames.ServerVpp, s.ContainerNames.Server, []string{"/bin/bash", "-c", symLink})

	_, err := s.Exec(s.PodNames.ClientVpp, s.ContainerNames.Client, []string{"/bin/bash", "-c", vclConf})
	s.AssertNil(err)
	_, err = s.Exec(s.PodNames.ServerVpp, s.ContainerNames.Server, []string{"/bin/bash", "-c", vclConf})
	s.AssertNil(err)

	_, err = s.Exec(s.PodNames.ServerVpp, s.ContainerNames.Server, []string{"/bin/bash", "-c",
		"VCL_CONFIG=" + vclPath + " LD_PRELOAD=" + ldpPath + " iperf3 -s -D -4"})
	s.AssertNil(err)
	output, err := s.Exec(s.PodNames.ClientVpp, s.ContainerNames.Client, []string{"/bin/bash", "-c",
		"VCL_CONFIG=" + vclPath + " LD_PRELOAD=" + ldpPath + " iperf3 -c " + s.ServerIp})
	s.Log(output)
	s.AssertNil(err)
}

func NginxRpsTest(s *KindSuite) {
	s.DeployServerClient(s.ImageNames.Nginx, s.ImageNames.Ab, s.PodNames.Nginx, s.PodNames.Ab)
	s.CreateNginxConfig()
	vcl := "VCL_CONFIG=/vcl.conf"
	ldp := "LD_PRELOAD=/usr/lib/libvcl_ldpreload.so"

	// temporary workaround
	symLink := "for file in /usr/lib/*.so; do\n" +
		"if [ -e \"$file\" ]; then\n" +
		"base=$(basename \"$file\")\n" +
		"newlink=\"/usr/lib/${base}.25.06\"\n" +
		"ln -s \"$file\" \"$newlink\"\n" +
		"fi\n" +
		"done"

	vclConf := "echo \"vcl {\n" +
		"heapsize 64M\n" +
		"rx-fifo-size 4000000\n" +
		"tx-fifo-size 4000000\n" +
		"segment-size 4000000000\n" +
		"add-segment-size 4000000000\n" +
		"event-queue-size 100000\n" +
		"use-mq-eventfd\n" +
		"app-socket-api abstract:vpp/session\n" +
		"}\" > /vcl.conf"

	out, err := s.Exec(s.PodNames.Nginx, s.ContainerNames.Server, []string{"/bin/bash", "-c", symLink})
	s.AssertNil(err, out)

	out, err = s.Exec(s.PodNames.Nginx, s.ContainerNames.Server, []string{"/bin/bash", "-c", vclConf})
	s.AssertNil(err, out)

	go func() {
		defer GinkgoRecover()
		out, err := s.Exec(s.PodNames.Nginx, s.ContainerNames.Server, []string{"/bin/bash", "-c", ldp + " " + vcl + " nginx -c /nginx.conf"})
		s.AssertNil(err, out)
	}()

	// wait for nginx to start up
	time.Sleep(time.Second * 2)
	out, err = s.Exec(s.PodNames.Ab, s.ContainerNames.Client, []string{"ab", "-k", "-r", "-n", "1000000", "-c", "1000", "http://" + s.ServerIp + ":80/64B.json"})
	s.Log(out)
	s.AssertNil(err)
}
